#!/usr/bin/env python3
"""capture_e5f3_state.py -- task #8 phase C, docs/AS-DESIGN.md section 11.

Captures the full machine state at the INSTANT control reaches $E5F3
(ASM_ENTRY) in two configurations of the SAME shipped patched core
(P1+P4+P5+P7+P9, src/merlin/patches.py):

  working  -- build/ascore.po, entered the normal way: MACED's own
              `L`/`ASM` command dispatch (check-ascore's own harness/
              technique). This assembly COMPLETES (check-ascore is
              green).
  direct   -- build/as.po, entered by as.s's own `JMP $E5F3` after its
              own front-end setup (astestb.s's harness: spawn sh, sh
              runs `AS GOODMOD.S -o GOODMOD.OBJ`). This run HANGS
              somewhere past this point (docs/AS-DESIGN.md section 8-10).

Captured per run: ZP+stack $00-$FF, the $E000-$E0FF resident parameter
block, page-3 $0300-$03FF, and the full softswitches()+regs() state --
docs/AS-DESIGN.md section 11's own list. BANK CHOICE (not a guess, see
learning:01M0CC62FZ351EBXCAAKX52KAJ and HACKING.md's bank-per-process
model):
  - working (plain ProDOS+Merlin, ALTZP-only aux relocation): ZP/stack
    read from 'aux' (no aux_bank -- matches check_asmspike.py's own
    entry-contract read); $E0xx and page3 read from 'main' (ALTZP alone
    does not relocate $0200-$BFFF, and check_asmspike confirms SOURCE
    lives in main $0901).
  - direct (a maux process IS its aux bank -- ARCHITECTURE.md/HACKING.md):
    ALL three ranges read from the SAME aux_bank the scheduler assigned
    the AS process, discovered live via softswitches()'s ramworks_bank
    at the halt (not assumed/hardcoded).

Output: build/e5f3_working.json / build/e5f3_direct.json (regs +
softswitches + hex dumps of the three ranges). Companion:
scripts/diff_e5f3_state.py.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import check_merlin_build as cmb  # noqa: E402  (wait/settle)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')

E5F3 = 0xE5F3
MENU = 'L :Load source'

RANGES = [('zp', 0x0000, 0x100), ('e0xx', 0xE000, 0x100),
          ('page3', 0x0300, 0x100)]


def new_client():
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    c.initialize()
    for unit in range(1, 7):
        c.call_tool('eject_disk', {'unit': unit})
    return c


def snapshot(c, bank, aux_bank):
    """Full state dict at the CURRENT PC (caller has already stopped
    exactly at $E5F3 via until_pc)."""
    sw = c.call_tool('softswitches', {})
    regs = c.call_tool('regs', {})
    out = {'softswitches': sw, 'regs': regs, 'bank': bank,
          'aux_bank': aux_bank, 'ranges': {}}
    for name, addr, count in RANGES:
        kwargs = {'addr': addr, 'count': count, 'bank': bank}
        if bank == 'aux' and aux_bank is not None:
            kwargs['aux_bank'] = aux_bank
        out['ranges'][name] = {
            'addr': addr,
            'bytes': c.call_tool('peek', kwargs)['bytes'],
        }
    return out


def capture_working():
    """MACED-driven entry: build/ascore.po, `LPACKOP2` / `ASM`, stop at
    $E5F3 -- exactly check-ascore's own (a) drive, but halted one step
    earlier than ASEXIT."""
    image = os.path.join(BUILD, 'ascore.po')
    c = new_client()
    try:
        c.call_tool('reset', {'backend': 'fast'})
        r = c.call_tool('mount_disk', {'path': os.path.abspath(image)})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        cmb.wait(c, MENU)
        cmb.settle(c)
        c.call_tool('type', {'text': 'LPACKOP2\r'})
        cmb.wait(c, 'Editor')
        cmb.settle(c)
        c.call_tool('type', {'text': 'ASM\r'})
        hit = c.call_tool('until_pc', {'pc': E5F3, 'max_cycles': 20_000_000})
        if not hit.get('hit'):
            raise RuntimeError(f'working run never reached $E5F3: {hit}')
        print(f'[capture] working: PC=$E5F3 reached, {hit}', file=sys.stderr)
        # ZP/stack: aux (ALTZP-relocated, plain 64K aux -- no aux_bank).
        snap = {'zp_aux': None}
        sw = c.call_tool('softswitches', {})
        regs = c.call_tool('regs', {})
        zp = c.call_tool('peek', {'addr': 0, 'count': 0x100,
                                  'bank': 'aux'})['bytes']
        e0xx = c.call_tool('peek', {'addr': 0xE000, 'count': 0x100,
                                    'bank': 'main'})['bytes']
        page3 = c.call_tool('peek', {'addr': 0x0300, 'count': 0x100,
                                     'bank': 'main'})['bytes']
        return {
            'label': 'working (MACED L/ASM, build/ascore.po, PACKOP2.S)',
            'softswitches': sw,
            'regs': regs,
            'ranges': {
                'zp': {'addr': 0, 'bank': 'aux', 'aux_bank': None,
                      'bytes': zp},
                'e0xx': {'addr': 0xE000, 'bank': 'main', 'bytes': e0xx},
                'page3': {'addr': 0x0300, 'bank': 'main', 'bytes': page3},
            },
        }
    finally:
        c.close()


def capture_direct():
    """as.s direct entry: build/as.po (astestb.s harness), boot straight
    through (no menu -- ENTRY runs at reset), stop at $E5F3 -- the
    instant AS's own `jmp ASM_ENTRY` (as.s's last setup instruction)
    lands. First waits for the "MAUX AS" banner so until_pc cannot
    false-fire on a stray ROM/boot-time PC==$E5F3 before the kernel/AS
    process is even running."""
    image = os.path.join(BUILD, 'as.po')
    c = new_client()
    try:
        c.call_tool('reset', {'backend': 'fast'})
        r = c.call_tool('mount_disk', {'path': os.path.abspath(image)})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        found = False
        for _ in range(60):
            c.call_tool('step', {'cycles': 500_000})
            st = c.call_tool('screen_text', {})
            rows = st.get('main', []) or st.get('merged', [])
            if any('MAUX AS' in row for row in rows):
                found = True
                break
        if not found:
            raise RuntimeError('never saw the MAUX AS banner')
        print('[capture] direct: MAUX AS banner seen, booting AS via sh',
              file=sys.stderr)
        hit = c.call_tool('until_pc', {'pc': E5F3, 'max_cycles': 150_000_000})
        if not hit.get('hit'):
            raise RuntimeError(f'direct run never reached $E5F3: {hit}')
        print(f'[capture] direct: PC=$E5F3 reached, {hit}', file=sys.stderr)
        sw = c.call_tool('softswitches', {})
        regs = c.call_tool('regs', {})
        aux_bank = sw.get('ramworks_bank')
        print(f'[capture] direct: ramworks_bank={aux_bank} ALTZP='
              f'{sw.get("ALTZP")}', file=sys.stderr)
        kw = {'bank': 'aux'}
        if aux_bank is not None:
            kw['aux_bank'] = aux_bank
        zp = c.call_tool('peek', dict(kw, addr=0, count=0x100))['bytes']
        e0xx = c.call_tool('peek', dict(kw, addr=0xE000, count=0x100))['bytes']
        page3 = c.call_tool('peek', dict(kw, addr=0x0300, count=0x100))['bytes']
        return {
            'label': 'direct (as.s JMP $E5F3, build/as.po, spawned via sh)',
            'softswitches': sw,
            'regs': regs,
            'ranges': {
                'zp': {'addr': 0, 'bank': 'aux', 'aux_bank': aux_bank,
                      'bytes': zp},
                'e0xx': {'addr': 0xE000, 'bank': 'aux', 'aux_bank': aux_bank,
                         'bytes': e0xx},
                'page3': {'addr': 0x0300, 'bank': 'aux', 'aux_bank': aux_bank,
                          'bytes': page3},
            },
        }
    finally:
        c.close()


def main():
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    os.makedirs(BUILD, exist_ok=True)
    which = sys.argv[1] if len(sys.argv) > 1 else 'both'
    if which in ('working', 'both'):
        snap = capture_working()
        out = os.path.join(BUILD, 'e5f3_working.json')
        with open(out, 'w') as fh:
            json.dump(snap, fh)
        print(f'[capture] wrote {out}')
    if which in ('direct', 'both'):
        snap = capture_direct()
        out = os.path.join(BUILD, 'e5f3_direct.json')
        with open(out, 'w') as fh:
            json.dump(snap, fh)
        print(f'[capture] wrote {out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
