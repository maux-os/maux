#!/usr/bin/env python3
"""check_plasm.py -- plasm ITSELF runs on maux and compiles a .pla
source to a .mod (`make check-plasm`, docs/PLASMA-PORT.md milestone 3).

Boots build/plasm.po (build_plasm_image.py: the play image plus
/mnt/MAUX/PLRT, whose syspath is now "/mnt/MAUX/PLLIB/", and /mnt/MAUX/PLLIB/
holding ARGS, FILEIO, LONGJMP, PLASM, T.PLA and inc/CMDSYS.PLH) and, at
the shell:

  PLD1 `cd /mnt/MAUX/pllib` -- puts the shell's own prefix at PLLIB so
       plasm's OWN runtime include (`include "inc/cmdsys.plh"` inside
       T.PLA, processed by lex.pla running ON MAUX, not a host-side
       thing) resolves the relative "inc/cmdsys.plh" to
       /mnt/MAUX/PLLIB/inc/CMDSYS.PLH, and so plasm's own argv[1]="PLASM"
       and the source/output filenames below can stay bare relative
       names instead of needing syspath's fallback for everything.
  PLD2 `plasma PLASM t.pla t.mod` -- rt (already resident as
       CMDSYS) execmods argv[1] (PLASM), which loadmod's recursive
       dependency walk resolves: ARGS, FILEIO, LONGJMP (CMDSYS is
       already resident). plasm.pla's FIRST action, unconditionally,
       is `puts("PLASMA Compiler v2.21\\n")` -- printed before it even
       looks at its own argv -- so that banner alone proves the whole
       load chain (4 modules, one of them 24 KB) relocated and ran.

       THE ARGUMENT CONVENTION (PLASM-FIX, docs/PLASM-FIX-NOTES.md).
       plasm.pla's own parser does `arg = argNext(argFirst)` before
       looking at anything: on a stock PLASMA system the command line
       is the WHOLE typed command including the program's own name, so
       plasm discards that first token by design. Until PLASM-FIX rt's
       buildcmdln() built the line from argv[2..] and this row had to
       pass a throwaway second "PLASM" (`plasma PLASM PLASM t.pla
       t.mod`), else plasm threw "t.pla" away and compiled "t.mod".
       The line now starts at the program's own name (argv[1], the
       module, on this seed path; argv[0] in a cooked binary), exactly
       as Dave's system presents it, so the row is the plain
       `plasma PLASM t.pla t.mod` -- the same arguments as the cooked
       /bin/plasm's (check-plasm-full).

       With that fixed, plasm parses its cmdline (via the ARGS
       module's argFirst/argNext) as `SRCFILE [RELFILE]`, opens t.pla
       through FILEIO's a2open/a23read (exercising the maux
       io_buffer=$0000 retarget and the NEWLINE emulation on every
       source line), and on success destroys/creates/writes t.mod
       through the same module.
  PLD3 a2til's write-through does not sync the LAST-written file back
       to the host .po, so t.mod's existence is verified IN the
       emulator: `plasma t.mod` loads it as a normal module (no
       dependencies -- T.PLA only imports the already-resident CMDSYS)
       and its init runs `puts("PLASM RAN\\n")`, which is the source
       byte-for-byte round-tripping through the whole pipeline: T.PLA
       on disk (plain low-ASCII, real ProDOS convention -- see
       build_plasm_image.py's header for why) -> lexed/parsed/
       codegen'd by plasm running as maux bytecode -> a REL module
       written back to the same disk -> loaded and RUN by the very
       same seed+rt that compiled it.

Boot/type/screen helpers are check_plasma.py's, itself check_dd.py's /
check_proshim.py's / check_play.py's (copied, not imported).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_play.py)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

BANNER = 'PLASMA Compiler'
RAN_LINE = 'PLASM RAN'


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
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].startswith('$')


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    failures = []
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                      'bank': 'main'})
        client.call_tool('mount_disk', {'path': disk})
        wait_for_screen(client, prompt_ready, 'shell prompt')
        print('[check-plasm] shell prompt reached')

        client.call_tool('type', {'text': 'cd /mnt/MAUX/pllib\r'})
        wait_for_screen(client, prompt_ready, 'PLD1: prompt after cd')
        print('[check-plasm] PLD1: cd /mnt/MAUX/pllib')

        client.call_tool('type', {'text': 'plasma PLASM t.pla t.mod\r'})
        try:
            wait_for_scrolling(client, [BANNER], f'PLD2: {BANNER!r}',
                               max_steps=8000)
            print(f'[check-plasm] PLD2: {BANNER!r}')
        except RuntimeError as e:
            failures.append(f'PLD2: {e}')
        rows = wait_for_screen(client, prompt_ready, 'PLD2: prompt',
                               max_steps=4000)
        # PLD2b: the code buffer plasm prints must be POSITIVE. A size
        # of $8000 or more is a negative number: `heapavail - 2048` went
        # below zero, plasm's overflow check can never fire, and the
        # compile "works" only by running into free heap (PLASM-FIX S2).
        m = re.search(r'Data\+Code buffer size = \$([0-9A-F]{1,4})',
                      screen_blob(rows))
        if not m:
            failures.append('PLD2b: no `Data+Code buffer size` line')
        elif int(m.group(1), 16) >= 0x8000 or int(m.group(1), 16) < 64:
            failures.append(f'PLD2b: code buffer ${m.group(1)} is not a '
                            'usable positive size (negative = the overflow '
                            'check is disabled by a heap shortage)')
        else:
            print(f'[check-plasm] PLD2b: code buffer ${m.group(1)} '
                  '(positive)')
        client.call_tool('type', {'text': 'echo PLC=$?\r'})
        try:
            wait_for_scrolling(client, ['PLC=0'], 'PLD2: exit 0',
                               max_steps=2000)
            print('[check-plasm] PLD2: exit 0')
        except RuntimeError as e:
            failures.append(f'PLD2-rc: {e}')
        wait_for_screen(client, prompt_ready, 'PLD2: prompt after echo')

        client.call_tool('type', {'text': 'plasma t.mod\r'})
        try:
            wait_for_scrolling(client, [RAN_LINE], f'PLD3: {RAN_LINE!r}',
                               max_steps=4000)
            print(f'[check-plasm] PLD3: {RAN_LINE!r}')
        except RuntimeError as e:
            failures.append(f'PLD3: {e}')
        wait_for_screen(client, prompt_ready, 'PLD3: prompt', max_steps=2000)
        client.call_tool('type', {'text': 'echo PLR=$?\r'})
        try:
            wait_for_scrolling(client, ['PLR=0'], 'PLD3: exit 0',
                               max_steps=2000)
            print('[check-plasm] PLD3: exit 0')
        except RuntimeError as e:
            failures.append(f'PLD3-rc: {e}')
        wait_for_screen(client, prompt_ready, 'PLD3: prompt after echo')
    finally:
        client.close()

    if failures:
        print('[check-plasm] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-plasm] PASS: plasm loaded (CMDSYS+ARGS+FILEIO+LONGJMP), '
          'compiled T.PLA to T.MOD through the maux FILEIO retarget, and '
          'the compiled module ran and printed PLASM RAN')
    return 0


if __name__ == '__main__':
    sys.exit(main())
