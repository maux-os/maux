#!/usr/bin/env python3
"""check_nas_rel.py -- nas L1b (`make check-nas-rel`, docs/AS-
PLASMA.md). PUT/USE splicing + REL object emission, proven end to
end: assemble -> link -> run, all inside maux.

Boots build/nas-rel.po (build_nas_rel_image.py: the play image plus
/mnt/MAUX/PLRT, /mnt/MAUX/PLLIB/{ARGS,FILEIO,NAS,LD,RELMAIN.S,RELSUB.S,
RELLIB.S}) across THREE separate boots of the SAME disk image --
check_nas.py's own precedent and its stated reason: "the second
file's write was observed to not reliably reach the host .po when run
right after the first one in the SAME session", so each `plasma NAS`
invocation gets its own fresh boot. ProDOS writes persist to the .po
file between boots, so boot 2 sees boot 1's RELMAIN.REL and boot 3
sees both.

  Boot A -- `cd /mnt/MAUX/pllib`, `plasma NAS -o RELMAIN.REL RELMAIN.S`.
      Assembles the PUT+EXT fixture: nas splices RELSUB.S inline
      (single-level PUT, docs/AS-PLASMA.md L1b) and emits a REL
      module -- ProDOS $F8, aux = code length, fixup list + symbol
      list per docs/REL-FORMAT.md. Exit status checked via `echo`.
  Boot B -- same shape, `plasma NAS -o RELLIB.REL RELLIB.S`. The
      library half (`LIBGREET ENT`).
  Boot C -- `LD -o OUT RELMAIN.REL RELLIB.REL` (maux's own native REL
      linker, build/ld.bin, staged bare as `LD` -- resolved via the
      shell's current-directory PATH fallback, src/bin/shblt2.s, the
      same way FIXTURE.S resolves as a bare argv word in check_nas.py)
      links the two modules boots A and B produced. `ld` prints
      nothing on success (its diagnostics are error-only, `ld: ...`-
      prefixed, src/bin/ldout.s) -- a returned prompt and `echo`'s own
      exit-status check is the signal. Then `OUT` spawns the LINKED
      program directly: `ld`'s default link address is LOAD_BASE
      ($0800, the SAME address a spawned process image loads at --
      scripts/build_ld_image.py's own note), so the freshly linked
      file is directly runnable with no `-a` needed. OUT computes
      LOCALCALL's return (5, spliced in via PUT) plus LIBGREET's
      return (10, the EXT/ENT cross-module call) and exits with that
      sum (15) via liba's own SC_EXIT convention (src/liba/
      syscalls.s), hand-rolled inline so the fixture needs no `put`
      of liba itself. THIS is the assemble -> link -> run proof: PUT
      spliced the right bytes, the EXT/ENT bind resolved to the right
      cross-module address, and every fixup `ld` applied landed at
      the right offset with the right value -- any one of those being
      wrong changes this number.

Boot C also links at $20F9, to exercise carry into high-byte fixups.
After it closes, every linked byte at BOTH bases must match merlin32's
flat assembly of the same fixtures. This covers the unexecuted expression
regression data as well as the runnable entry point. REL dictionary order
need not match an oracle; the independently assembled linked bytes must.

Boot/type/screen helpers are check_plasm.py's / check_nas.py's
(copied, not imported).
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_play.py)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

EXPECT_STATUS = 15   # LOCALCALL (5, spliced via PUT) + LIBGREET (10, EXT/ENT)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def screen_blob(rows):
    return '\n'.join(rows)


def wait_for_screen(client, predicate, label, max_steps=1200):
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 200_000})
        rows = screen_rows(client)
        if predicate(rows):
            return rows
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def wait_for_scrolling(client, needles, label, max_steps=8000):
    seen = set()
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 20_000})
        rows = screen_rows(client)
        blob = screen_blob(rows)
        for name in needles:
            if name in blob:
                seen.add(name)
        if seen.issuperset(needles):
            return rows
    missing = sorted(set(needles) - seen)
    raise RuntimeError(
        f'timed out waiting for {label}; never saw {missing}; screen was:\n'
        f'{screen_blob(rows)}')


def prompt_ready(rows):
    # STRICT: the last non-blank row must be a BARE prompt ("$",
    # trailing spaces only) -- not merely a row that STARTS with '$',
    # which also matches the shell's own echo of a still-in-flight
    # typed command line ("$ cd /mnt/MAUX/pllib"). The looser
    # startswith('$') check races exactly there in a multi-command
    # session: it can return true while a command's echo row is still
    # the last line on screen, so the NEXT `type` call fires before
    # the terminal has genuinely returned to idle, and the two
    # keystroke streams interleave (observed directly, first draft of
    # this script: `NAS` arrived as `N$ AS`, a stray prompt character
    # landed mid-word).
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].strip() == '$'


def type_and_wait_prompt(client, text, tag, max_steps=4000):
    client.call_tool('type', {'text': text})
    return wait_for_screen(client, prompt_ready, f'{tag}: prompt',
                            max_steps=max_steps)


def check_exit(client, tag, want, failures, max_steps=2000):
    # THE MARKER MUST BE UNIQUE PER CALL (check_rel.py's own driving
    # note: "waiting on a marker that is already on screen returns
    # instantly and desynchronises the whole sequence"). Folding the
    # tag into the echoed text keeps every occurrence textually
    # distinct even across the small number of echoes one boot does.
    needle = f'{tag}={want}'
    client.call_tool('type', {'text': f'echo {tag}=$?\r'})
    try:
        wait_for_scrolling(client, [needle], f'{tag}: exit {want}',
                           max_steps=max_steps)
        print(f'[check-nas-rel] {tag}: exit {want}')
    except RuntimeError as e:
        failures.append(f'{tag}: {e}')
    wait_for_screen(client, prompt_ready, f'{tag}: prompt after echo')


def boot(disk):
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.call_tool('reset', {'backend': 'fast'})
    for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                      (PT_F40B_ADDR, PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                  'bank': 'main'})
    client.call_tool('mount_disk', {'path': disk})
    wait_for_screen(client, prompt_ready, 'shell prompt')
    return client


def assemble_one(disk, srcname, objname, tag):
    """Boot A / Boot B: `plasma NAS -o <objname> <srcname>` in its own
    fresh boot (check_nas.py's own reason: chaining two `plasma NAS`
    invocations in one boot risks the second file's write not
    reliably reaching the host .po). Returns the failure list."""
    failures = []
    client = boot(disk)
    try:
        print(f'[check-nas-rel] [{tag}] shell prompt reached')
        type_and_wait_prompt(client, 'cd /mnt/MAUX/pllib\r', f'{tag}-cd')
        print(f'[check-nas-rel] [{tag}] cd /mnt/MAUX/pllib')

        client.call_tool('type',
                          {'text': f'plasma NAS -o {objname} {srcname}\r'})
        try:
            # "bytes -> OBJNAME" is nas's OWN success line (run()'s
            # final puts chain) -- unlike the bare object name, this
            # substring cannot be satisfied by the typed command's own
            # on-screen echo, only by nas actually finishing.
            wait_for_scrolling(client, [f'bytes -> {objname}'],
                               f'[{tag}] {objname}', max_steps=8000)
            print(f'[check-nas-rel] [{tag}] nas -> {objname}')
        except RuntimeError as e:
            failures.append(f'[{tag}]: {e}')
        wait_for_screen(client, prompt_ready, f'[{tag}] prompt',
                        max_steps=4000)
        check_exit(client, f'{tag}-NC', 0, failures)

        # One more filesystem op (check_plasm.py's PLD3 note): a2til's
        # write-through does not reliably sync the LAST file an
        # emulator session wrote.
        type_and_wait_prompt(client, 'ls\r', f'{tag}-ls', max_steps=2000)
        print(f'[check-nas-rel] [{tag}] ls (flush nudge)')
    finally:
        client.close()
    return failures


def link_and_run(disk):
    """Boot C: link RELMAIN.REL+RELLIB.REL with `ld`, then spawn the
    linked program and read its exit status."""
    failures = []
    client = boot(disk)
    try:
        print('[check-nas-rel] [C] shell prompt reached')
        type_and_wait_prompt(client, 'cd /mnt/MAUX/pllib\r', 'C-cd')
        print('[check-nas-rel] [C] cd /mnt/MAUX/pllib')

        # THE COMMAND WORD must be an ABSOLUTE path. A bare `LD`
        # resolves through sh's own BUILD_PATH/PATHTAB (src/bin/
        # shpath.s), which has no reason to include /mnt/MAUX/PLLIB and
        # correctly reports "command not found" rather than falling
        # back to a current-directory search (that back door was
        # closed -- src/bin/shblt2.s's own comment names it and shows
        # the fixed carry-check). The REST of the line (ld's own
        # module/output arguments) still resolves relative to the
        # shell's prefix, same as nas's own arguments already do.
        type_and_wait_prompt(
            client, '/mnt/MAUX/pllib/LD -o OUT RELMAIN.REL RELLIB.REL\r',
            'C-ld', max_steps=4000)
        print('[check-nas-rel] [C] LD -o OUT RELMAIN.REL RELLIB.REL')
        check_exit(client, 'C-LDNC', 0, failures)

        # Run the LINKED program directly (absolute path, same
        # reason). It exits via SC_EXIT with LOCALCALL+LIBGREET's sum
        # as its status.
        type_and_wait_prompt(client, '/mnt/MAUX/pllib/OUT\r', 'C-run',
                             max_steps=2000)
        print('[check-nas-rel] [C] /mnt/MAUX/pllib/OUT')
        check_exit(client, 'C-RUNNC', EXPECT_STATUS, failures)

        # A non-page-aligned base exposes lost low-byte carry in the
        # internal high-selector fixup, invisible at the default $0800.
        type_and_wait_prompt(
            client, '/mnt/MAUX/pllib/LD -a 20F9 -o OUTALT RELMAIN.REL RELLIB.REL\r',
            'C-alt', max_steps=4000)
        check_exit(client, 'C-ALTNC', 0, failures)

        type_and_wait_prompt(client, 'ls\r', 'C-ls', max_steps=2000)
        print('[check-nas-rel] [C] ls (flush nudge)')
    finally:
        client.close()
    return failures


def linked_reference(base):
    """Flatten the SAME fixture inputs for an independent merlin32 oracle.

    Only REL/EXT/ENT and PUT packaging changes; operand expressions stay
    verbatim. In particular, no expected fixups or bytes come from nas.
    Use a private directory so the oracle leaves the source tree alone.
    """
    source_dir = Path(ROOT) / 'src/test/asm'

    def flatten(name):
        lines = []
        for line in (source_dir / name).read_text(encoding='ascii').splitlines():
            if line.startswith('*'):
                lines.append(line)
                continue
            put = re.fullmatch(r'\s+PUT\s+(\w+)\s*', line, re.I)
            if put:
                lines.extend(flatten(put[1].lower() + '.s'))
            elif re.fullmatch(r'\s+REL\s*', line, re.I):
                continue
            elif re.fullmatch(r'\w+\s+EXT\s*', line, re.I):
                continue
            elif re.fullmatch(r'\w+\s+ENT\s*', line, re.I):
                lines.append(line.split()[0])
            else:
                lines.append(line)
        return lines

    lines = [f' ORG ${base:04X}', ' DSK oracle.bin']
    lines += flatten('relmain.s') + flatten('rellib.s')
    with tempfile.TemporaryDirectory(prefix='nas-rel-oracle-') as tmp:
        source = Path(tmp) / 'oracle.s'
        source.write_text('\n'.join(lines) + '\n', encoding='ascii')
        result = subprocess.run(
            [os.environ.get('MERLIN32', 'merlin32'), source.name],
            cwd=tmp, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('merlin32 oracle failed:\n' + result.stdout +
                               result.stderr)
        return (Path(tmp) / 'oracle.bin').read_bytes()


def compare_linked(name, actual, expected):
    if actual != expected:
        offset = next((i for i, (a, b) in enumerate(zip(actual, expected))
                       if a != b), min(len(actual), len(expected)))
        raise RuntimeError(f'{name}: merlin32 mismatch at byte {offset}; '
                           f'nas+ld {len(actual)}B, oracle {len(expected)}B')
    print(f'[check-nas-rel] {name}: {len(actual)}B byte-identical to merlin32')


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])

    failures = []
    failures += assemble_one(disk, 'RELMAIN.S', 'RELMAIN.REL', 'A')
    failures += assemble_one(disk, 'RELLIB.S', 'RELLIB.REL', 'B')
    failures += link_and_run(disk)

    if failures:
        print('[check-nas-rel] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1

    # The linked code bytes MUST match an independent flat assembly.
    # Dictionary ordering is immaterial; every emitted field is checked.
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        for name in ('RELMAIN.REL', 'RELLIB.REL', 'OUT', 'OUTALT'):
            try:
                data = prodos.read(f'/mnt/MAUX/PLLIB/{name}')
                ent = prodos.stat(f'/mnt/MAUX/PLLIB/{name}')
                print(f'[check-nas-rel] {name}: {len(data)}B on-image, '
                      f'type ${ent.type:02X} aux ${ent.aux_type:04X}')
                if name in ('OUT', 'OUTALT'):
                    compare_linked(name, data, linked_reference(
                        0x0800 if name == 'OUT' else 0x20F9))
            except FileNotFoundError:
                raise RuntimeError(f'{name}: MISSING on-image')
    finally:
        prodos.unmount(vol)

    print('[check-nas-rel] PASS: nas assembled RELMAIN.S (with a spliced '
          'PUT and an EXT reference) and RELLIB.S (with an ENT export) to '
          'REL objects, `ld` linked them, and the linked program RAN and '
          f'exited with status {EXPECT_STATUS} -- LOCALCALL (spliced by '
          'PUT) + LIBGREET (resolved across the REL link) computed '
          'correctly; linked bytes at $0800 and $20F9 match merlin32')
    return 0


if __name__ == '__main__':
    sys.exit(main())
