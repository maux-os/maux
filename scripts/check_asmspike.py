#!/usr/bin/env python3
"""check_asmspike.py -- task #8 spike: prove Merlin's assembler core is
reachable at a fixed vector, headless, so `as` can be a shim rather than a
port (docs/SELFHOST.md).

WHAT THIS PROVES (and it is deliberately narrow):

  1. Merlin-8 2.59 boots headless under verilogapple and reaches its `%` menu.
  2. A source file loads from the menu.
  3. The `:` prompt's ASM command assembles it.
  4. *** Control reaches ASMBLER = $E5F3. *** This is the load-bearing
     assertion. MACED.S:64 declares `ASS = $E5F0` / `ASMBLER = ASS+3`, and
     MACED.S:958 reaches it with a plain `JMP`. If an argv front end can set
     up the same state and jump here, `as` never involves the editor.
  5. The documented entry contract holds, measured: ALTZP set, SWEET-16
     R0/R1/R2 zeroed, R5/R6/R7 = SOURCE/HIMEM/ENDSRC. See
     assert_entry_contract() -- and note the ALTZP trap documented there.
  6. The assembly completes with the known-good result: PACKOP2.S is 71 bytes
     of object, 0 errors, matching the PACKOP2 BIN file shipped beside it
     (catalog shows $47 = 71 bytes).

WHAT THIS DOES NOT PROVE, stated so nobody reads more into a green run:
  - that $E5F3 works with NO editor resident (here the editor is loaded and
    is what jumps to the vector);
  - the $E0xx parameter block ($BDC0 restores $E00A-$E00F from it) is still
    only partly mapped. The ENTRY CONTRACT itself is now verified -- see
    assert_entry_contract() -- so `as` can set it up directly rather than by
    capture-and-replay.

Needs vendor/VALIDATE.PO -- run `make vendor-merlin` first (gitignored).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'vendor', 'VALIDATE.PO')

ASMBLER = 0xE5F3          # MACED.S:64  ASS = $E5F0 ; ASMBLER = ASS+3
SRC_BUF = 0x0901          # PARMS.S     SOURCE = $901
EXPECT_BYTES = 71         # PACKOP2 BIN on the same volume is $47 bytes
SRC_LEN = 456             # PACKOP2.S, per the volume catalog


def screen(client):
    return '\n'.join(client.call_tool('screen_text', {}).get('merged', []))


def wait_for(client, needle, label, chunk=2_000_000, tries=40):
    blob = ''
    for _ in range(tries):
        client.call_tool('step', {'cycles': chunk})
        blob = screen(client)
        if needle in blob:
            return blob
    raise RuntimeError(f'timed out waiting for {label!r}; screen was:\n{blob}')


def assert_entry_contract(client):
    """Verify the assembler's documented entry contract, measured at $E5F3.

    THE TRAP: Merlin runs with ALTZP SET. Its zero page -- and therefore every
    SWEET-16 register -- lives in AUX, not main. Reading main ZP here produces
    plausible-looking garbage (R5 reads $FB09 instead of $0901) and sends you
    hunting for a pointer-layout bug that does not exist. maux of all systems
    should not be surprised by an ALTZP trap.
    """
    out = []
    sw = client.call_tool('softswitches', {})
    if not sw.get('ALTZP'):
        out.append('ALTZP is not set at entry -- the ZP reads below are then '
                   'against the wrong bank and the contract is unverified')
    zp = client.call_tool('peek',
                          {'addr': 0, 'count': 16, 'bank': 'aux'})['bytes']
    w = lambda n: zp[n] | (zp[n + 1] << 8)   # noqa: E731
    regs = client.call_tool('regs', {})
    print(f"[check-asmspike] entry regs: a=${regs['a']:02X} "
          f"x=${regs['x']:02X} y=${regs['y']:02X} s=${regs['s']:02X}"
          f"  (ALTZP={bool(sw.get('ALTZP'))}, COL80={bool(sw.get('COL80'))})")
    print('[check-asmspike] entry aux ZP $00-$0F: '
          + ' '.join(f'{b:02X}' for b in zp))

    # SWEET-16 registers. MACED declares SOURCE=5/HIMEM=6/ENDSRC=7 as REGISTER
    # NUMBERS; MACASS declares SOURCE=$A, which is R5's byte address.
    for name, reg in (('R0', 0), ('R1', 2), ('R2', 4)):
        if w(reg) != 0:
            out.append(f'{name} (ZP ${reg:02X}) = ${w(reg):04X}, expected $0000 '
                       f'-- "0-5 must contain 0 on entry to assembler"')
    checks = [
        ('R5 SOURCE', 0x0A, SRC_BUF,        'PARMS declares SOURCE = $901'),
        ('R6 HIMEM',  0x0C, 0xAA00,         'PARMS: DA $AA00 "Don\'t change this"'),
        ('R7 ENDSRC', 0x0E, SRC_BUF + SRC_LEN,
         f'SOURCE + PACKOP2.S length ({SRC_LEN})'),
    ]
    for name, addr, want, why in checks:
        got = w(addr)
        if got != want:
            out.append(f'{name} (ZP ${addr:02X}) = ${got:04X}, expected '
                       f'${want:04X} -- {why}')
        else:
            print(f'[check-asmspike]   {name:<10} = ${got:04X}  ({why})')
    if not out:
        print('[check-asmspike] entry contract verified: ALTZP set, R0/R1/R2 '
              'zeroed, SOURCE/HIMEM/ENDSRC as documented')
    return out


def main():
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run `make vendor-merlin` first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    failures = []
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        r = client.call_tool('mount_disk', {'path': os.path.abspath(DISK)})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # NOT 'MERLIN-8': that appears on the SPLASH screen as well and
        # matches long before the menu is up, so a command typed on the
        # strength of it lands nowhere. Wait for a menu-only line.
        wait_for(client, 'L :Load source', 'the Merlin boot menu')
        print('[check-asmspike] Merlin-8 2.59 booted to its % menu')

        # Merlin's Load appends the source suffix itself -- STEPBYSTEP says
        # enter 'INTERPRETER', not 'INTERPRETER.S'. Passing the .S form gets
        # "46 FILE NOT FOUND", which is a confusing way to learn this.
        client.call_tool('type', {'text': 'LPACKOP2\r'})
        wait_for(client, ':', 'the ED/ASM prompt after loading')

        loaded = client.call_tool('peek', {
            'addr': SRC_BUF, 'count': 8, 'bank': 'main'})['bytes']
        text = ''.join(chr(b & 0x7F) for b in loaded)
        if 'TR' not in text and 'ORG' not in text:
            failures.append(f'source buffer ${SRC_BUF:04X} does not hold '
                            f'PACKOP2.S text; got {text!r}')
        else:
            print(f'[check-asmspike] source present at ${SRC_BUF:04X}: {text!r}')

        client.call_tool('type', {'text': 'ASM\r'})
        # VALIDATE.PO ships no PARMS file, so MACED's built-in SEARCHR default
        # ("/" = $AF, negative) leaves the "Update source (Y/N)?" question ON.
        # The shipping v2.58 disk's PARMS sets that byte to 0 and skips it.
        blob = wait_for(client, 'Update source', 'the update-source question')
        client.call_tool('type', {'text': 'N'})

        hit = client.call_tool('until_pc',
                               {'pc': ASMBLER, 'max_cycles': 20_000_000})
        if not hit.get('hit'):
            failures.append(f'control never reached ASMBLER ${ASMBLER:04X} '
                            f'(this is the whole point of the spike): {hit}')
        else:
            print(f'[check-asmspike] PC reached ASMBLER ${ASMBLER:04X} '
                  f'-- the vector is real and callable')
            failures += assert_entry_contract(client)

        blob = wait_for(client, 'End assembly', 'assembly to finish', tries=60)
        line = next((l for l in blob.splitlines() if 'End assembly' in l), '')
        print(f'[check-asmspike] {line.strip()}')
        if f'{EXPECT_BYTES} bytes' not in line:
            failures.append(f'expected {EXPECT_BYTES} bytes of object, got: '
                            f'{line.strip()!r}')
        if 'Errors: 0' not in line:
            failures.append(f'assembly reported errors: {line.strip()!r}')

        if failures:
            for f in failures:
                print(f'[check-asmspike] FAIL: {f}', file=sys.stderr)
            return 1
        print('[check-asmspike] PASS: Merlin assembles headless, and the '
              'assembler core is reachable at a fixed vector -- `as` can be a '
              'shim over $E5F3 rather than a port')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
