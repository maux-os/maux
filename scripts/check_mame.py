#!/usr/bin/env python3
"""check_mame.py -- boot maux on MAME, the SECOND emulator rig.

Two phases, both headless (`-video none`), both asserted from inside the
machine via a Lua autoboot script rather than by screenshot-diffing:

  1. hello  -- build/maux.po on an AppleIISd card in slot 7. The block-0
     bootblock must put "MAUX ALIVE" on the 40-column text page.
  2. play   -- build/play.po (ProDOS + kernel + userland) on the same
     card, with RamWorks III in the aux slot, an UltraTerm in slot 3 and
     a Mockingboard in slot 4. The gate types `ls` at the shell and
     asserts the directory listing AND a fresh prompt in the UltraTerm's
     VRAM.
  3. play-mouse -- the same image with the AppleMouse in slot 5 instead
     of the Mockingboard. MAME's a2mouse emulates the card's REAL 68705
     mask ROM (dump vendored from the apple2.org.za mirror), so this
     phase exercises the genuine INITMOUSE/SETMOUSE/SERVEMOUSE
     handshake protocol -- the one verilogapple's behavioral model is
     lenient about -- plus the MAIN_IRQ_SHIM's mouse branch (ticks
     landing in the a2sd driver's CLI windows while in mouse mode).

  4. type-ahead under I/O (see main()).
  5. bye-drain -- `bye /mnt/MAUX/TENANT.SYSTEM` round trips on the
     AppleMouse tier, once as is and once with a VBL tick FORCED to be
     latched when TMR_QUIESCE runs (KFIX6 item 1; docs/KFIX6-NOTES.md).
     The 68705 in MAME is the card's real mask ROM, so this is the
     independent check that its controller answers the drain's M_SERV
     whether a tick is latched or not (the reply byte is $08 / $00),
     and that without the drain a latched tick is taken in the a2sd
     driver's CLI window mid-QUIT and wedges the machine.
     `--bye-only` runs just this phase; `--play PO --sym TXT` point it at
     another build (the teeth: a kernel without the drain).

Machine config notes (each cost a debugging session -- docs/MAME.md):
  * nvram/ is DELETED before every run. MAME persists the AppleIISd's
    EEPROM, and guest writes into $C800 space (that is what the pre-fix
    UT_CLAIM did) corrupt the card's own firmware ACROSS RUNS.
  * -sl6 "" clears the default Disk II controller (its ROMs are not
    vendored); the Mockingboard drags in a Votrax SC-01 whose romset is
    satisfied by a placeholder (MAME warns on the checksum and runs).
  * VRAM is read back through the $CC00 window after a $CFFF release +
    $C30C claim -- the same release-then-claim protocol the kernel had
    to learn (see UT_CLAIM).

`make check-mame` builds vendor/mameroms itself (vendor-mame-roms);
needs `mame` on PATH (brew install mame). Usage: python3 scripts/check_mame.py
"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
WORK = os.path.join(BUILD, 'mame')
ROMS = os.path.join(ROOT, 'vendor', 'mameroms')
MAME = shutil.which('mame')
#: MAUX_DIRTY_FILL=ff|ffff0000|zero runs every phase on a dirty RamWorks;
#: the byte pattern tiles each bank (same names as mcp_drive.DIRTY_FILLS).
#: check-mame is MANUAL (needs `brew install mame`): not in the sweep.
DIRTY_BYTES = {'ff': [255], 'zero': [0], 'ffff0000': [255, 255, 0, 0]}

#: KFIX11 (docs/KFIX11.md item 4): MAME's apple2ee powers up main RAM as
#: 00 FF 00 FF... but its RamWorks III as ALL ZEROS, so a stock run can
#: never see an aux-bank read-before-write. This prelude fills the card's
#: first @BANKS@ banks ($0200-$BFFF, the annex span) with the pattern through
#: the CPU's own address space (the $C073 bank select and RAMWRT aux),
#: before the ROM has run a cycle, then restores the switches.
DIRTY_PRELUDE = r"""
do
  local mem = manager.machine.devices[":maincpu"].spaces["program"]
  local pat = {@FILL@}
  for bank = 0, @BANKS@ - 1 do
    mem:write_u8(0xC073, bank)
    mem:write_u8(0xC005, 0)          -- RAMWRT aux
    for a = 0x0200, 0xBFFF do mem:write_u8(a, pat[a % #pat + 1]) end
    mem:write_u8(0xC004, 0)          -- RAMWRT main
  end
  mem:write_u8(0xC073, 0)
end
"""


HELLO_LUA = r"""
local frames = 0
gate_sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == 300 then
    local mem = manager.machine.devices[":maincpu"].spaces["program"]
    local s = ""
    for col = 0, 39 do
      local b = mem:read_u8(0x400 + col) & 0x7f
      if b < 32 then b = 46 end
      s = s .. string.char(b)
    end
    print("ROW0:[" .. s .. "]")
    manager.machine:exit()
  end
end)
"""

PLAY_LUA = r"""
local frames = 0
gate_sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == 800 then manager.machine.natkeyboard:post("ls\n") end
  if frames == 1400 then
    local mem = manager.machine.devices[":maincpu"].spaces["program"]
    mem:write_u8(0xC006, 0)  -- INTCXROM off
    mem:write_u8(0xC00B, 0)  -- SLOTC3ROM: slot 3 external
    mem:read_u8(0xCFFF)      -- release $C800 (see UT_CLAIM)
    mem:read_u8(0xC30C)      -- claim for the UltraTerm
    local ring = ""
    for page = 0, 15 do
      mem:write_u8(0xC0B2, 0x50 + page)  -- VIDSEL|VTEMU|page
      for i = 0, 255 do
        local b = mem:read_u8(0xCC00 + i) & 0x7f
        if b < 32 then b = 46 end
        ring = ring .. string.char(b)
      end
    end
    for r = 0, 50 do
      local row = ring:sub(r * 80 + 1, r * 80 + 80)
      if row:match("[^%. ]") then
        print(string.format("VROW%02d:[%s]", r, row))
      end
    end
    manager.machine:exit()
  end
end)
"""


SYNC_LUA = r"""
local frames = 0
local utscr
for tag, _ in pairs(manager.machine.screens) do
  if tag:find("uterm") then utscr = tag end
end
local f0, t0
gate_sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local scr = manager.machine.screens[utscr]
  if frames == 800 then manager.machine.natkeyboard:post("ls\n") end
  if frames == 1200 then f0 = scr:frame_number(); t0 = emu.time() end
  if frames == 1400 then
    -- the mc6845's registers, from its save-state items (the device's
    -- state table is nil; its items table maps "0/m_name" to an index
    -- for emu.item)
    local names = {"m_horiz_char_total", "m_horiz_disp",
      "m_horiz_sync_pos", "m_sync_width", "m_vert_char_total",
      "m_vert_total_adj", "m_vert_disp", "m_vert_sync_pos",
      "m_mode_control", "m_max_ras_addr", "m_cursor_start_ras",
      "m_cursor_end_ras"}
    for tag, dev in pairs(manager.machine.devices) do
      if tag:find("mc6845") then
        local vals = {}
        for _, n in ipairs(names) do
          vals[#vals + 1] = tostring(emu.item(dev.items["0/" .. n]):read(0))
        end
        print("UTREGS " .. table.concat(vals, " "))
      end
    end
    print(string.format("UTSYNC frames=%d secs=%.4f height=%d",
          scr:frame_number() - f0, emu.time() - t0, scr.height))
    local mem = manager.machine.devices[":maincpu"].spaces["program"]
    mem:write_u8(0xC006, 0)  -- INTCXROM off
    mem:write_u8(0xC00B, 0)  -- SLOTC3ROM: slot 3 external
    mem:read_u8(0xCFFF)
    mem:read_u8(0xC30C)
    local ring = ""
    for page = 0, 15 do
      mem:write_u8(0xC0B2, 0x50 + page)
      for i = 0, 255 do
        local b = mem:read_u8(0xCC00 + i) & 0x7f
        if b < 32 then b = 46 end
        ring = ring .. string.char(b)
      end
    end
    for r = 0, 50 do
      local row = ring:sub(r * 80 + 1, r * 80 + 80)
      if row:match("[^%. ]") then
        print(string.format("VROW%02d:[%s]", r, row))
      end
    end
    manager.machine:exit()
  end
end)
"""


TYPEAHEAD_LUA = r"""
local frames = 0
gate_sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  -- MAME boots the IIe with Caps Lock engaged (a TOGGLE field: it
  -- flips on key PRESSES, not value writes -- simulate one).
  -- ed's commands are lowercase.
  if frames == 100 then
    manager.machine.ioport.ports[":keyb_special"]
      .fields["Caps Lock"]:set_value(1)
  end
  if frames == 105 then
    manager.machine.ioport.ports[":keyb_special"]
      .fields["Caps Lock"]:clear_value()
  end
  if frames == 800 then
    -- everything after "ed x" arrives WHILE ed's 44KB binary is
    -- still streaming off the disk: the type-ahead test.
    manager.machine.natkeyboard:post("ed x\na\nmidload line\n.\nw x\nq\n")
  end
  if frames == 2200 then manager.machine.natkeyboard:post("ls\n") end
  if frames == 2800 then
    local mem = manager.machine.devices[":maincpu"].spaces["program"]
    mem:write_u8(0xC006, 0)
    mem:write_u8(0xC00B, 0)
    mem:read_u8(0xCFFF)
    mem:read_u8(0xC30C)
    local ring = ""
    for page = 0, 15 do
      mem:write_u8(0xC0B2, 0x50 + page)
      for i = 0, 255 do
        local b = mem:read_u8(0xCC00 + i) & 0x7f
        if b < 32 then b = 46 end
        ring = ring .. string.char(b)
      end
    end
    for r = 0, 50 do
      local row = ring:sub(r * 80 + 1, r * 80 + 80)
      if row:match("[^%. ]") then
        print(string.format("VROW%02d:[%s]", r, row))
      end
    end
    manager.machine:exit()
  end
end)
"""


BYE_LUA = r"""
local frames = 0
gate_sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local nk = manager.machine.natkeyboard
  if frames == 800 then nk:post("pwd\n") end
  if frames == 995 then
    local d = manager.machine.debugger
    @ARM@
  end
  if frames == 1000 then nk:post("bye /mnt/MAUX/TENANT.SYSTEM\n") end
  -- the round trip is ~440 frames; leave a wide margin, then prove the
  -- shell is alive and the tenant's file is there
  if frames == 1900 then nk:post("ls /mnt/MAUX\n") end
  if frames == 2200 then nk:post("echo alive\n") end
  if frames == 2500 then
    local mem = manager.machine.devices[":maincpu"].spaces["program"]
    mem:write_u8(0xC006, 0)
    mem:write_u8(0xC00B, 0)
    mem:read_u8(0xCFFF)
    mem:read_u8(0xC30C)
    local ring = ""
    for page = 0, 15 do
      mem:write_u8(0xC0B2, 0x50 + page)
      for i = 0, 255 do
        local b = mem:read_u8(0xCC00 + i) & 0x7f
        if b < 32 then b = 46 end
        ring = ring .. string.char(b)
      end
    end
    for r = 0, 50 do
      local row = ring:sub(r * 80 + 1, r * 80 + 80)
      if row:match("[^%. ]") then
        print(string.format("VROW%02d:[%s]", r, row))
      end
    end
    manager.machine:exit()
  end
end)
"""


def sym_addr(symfile, name):
    """An address from the kernel's merlin32 -v1 dump (same source
    check_tenant.py reads), so nothing is copied into this script."""
    with open(symfile) as f:
        m = re.search(r'^\s*' + re.escape(name) + r'\s*=\s*\$([0-9A-Fa-f]+)',
                      f.read(), re.M)
    if not m:
        sys.exit(f'error: {name} not in {symfile}')
    return int(m.group(1), 16)


def force_latch_arm(symfile):
    """Debugger commands (as Lua) that make a VBL tick LATCH before
    TMR_QUIESCE, exactly as check_tenant.py row 9 does on verilogapple:
    at PRC_BYE's entry, poke a stub into KBSS's spare tail ($0FF0) that
    masks, spins ~20 k cycles (longer than a 60 Hz tick) and jumps to
    TMR_QUIESCE, and point K_HALT_TMR at it. Three logging breakpoints
    prove the forcing actually ran (a force that did not fire proves
    nothing)."""
    prc_bye = sym_addr(symfile, 'PRC_BYE')
    halt = sym_addr(symfile, 'K_HALT_TMR')
    quiesce = sym_addr(symfile, 'TMR_QUIESCE')
    stall = 0x0FF0
    stub = [0x08, 0x78,              # php / sei
            0xA2, 0x10,              # ldx #16
            0xA0, 0x00,              # ldy #0
            0x88, 0xD0, 0xFD,        # dey / bne -3
            0xCA, 0xD0, 0xF8,        # dex / bne ldy
            0x28,                    # plp
            0x4C, quiesce & 0xFF, quiesce >> 8]
    pokes = [(stall + i, b) for i, b in enumerate(stub)]
    pokes += [(halt, stall & 0xFF), (halt + 1, stall >> 8)]
    wr = ';'.join(f'b@{a:X}={v:X}' for a, v in pokes)
    return (f'd:command([[bpset {prc_bye:X},1,{{printf "PRC_BYE hit\\n";'
            f'{wr};go}}]])\n'
            f'    d:command([[bpset {stall:X},1,'
            f'{{printf "STALL hit\\n";go}}]])\n'
            f'    d:command([[bpset {quiesce:X},1,'
            f'{{printf "QUIESCE hit\\n";go}}]])')


def bye_phase(play_po, symfile, force):
    """One `bye` round trip on the AppleMouse tier. Returns
    (problems, hits): problems is a list of strings, hits the ordered
    debugger breakpoint hits."""
    shutil.copyfile(play_po, os.path.join(WORK, 'bye.hdv'))
    arm = force_latch_arm(symfile) if force else ''
    args = ['apple2ee', '-aux', 'rw3', '-sl3', 'ultratermenh',
            '-sl5', 'mouse', '-sl4', '', '-sl6', '', '-sl7', 'a2sd',
            '-hard', 'bye.hdv']
    if force:
        args += ['-debug', '-debugger', 'none', '-debuglog']
    dlog = os.path.join(WORK, 'debug.log')
    if os.path.exists(dlog):
        os.remove(dlog)
    out = run_mame(args, 'bye.lua', BYE_LUA.replace('@ARM@', arm), 50)
    vrows = [l for l in out.splitlines() if l.startswith('VROW')]
    blob = '\n'.join(vrows).lower()
    rows = [l.split('[', 1)[1].rstrip('] ').strip().lower() for l in vrows]
    hits = []
    if force and os.path.exists(dlog):
        with open(dlog, errors='replace') as f:
            hits = [l.split()[0] for l in f if l.rstrip().endswith(' hit')]
    problems = []
    # whole rows, not substrings: the tty echoes typed text without the
    # shell's help, so `echo alive` on screen proves nothing -- the
    # OUTPUT row `alive` does.
    for needle, why in (('welcome back.', 'the return line'),
                        ('alive', 'the shell answering afterwards')):
        if needle not in rows:
            problems.append(f'missing {why} ({needle!r})')
    if 'bye.mark' not in blob:
        problems.append("missing the file the tenant wrote ('bye.mark')")
    if force and hits != ['PRC_BYE', 'STALL', 'QUIESCE']:
        problems.append(f'the forced latch did not run as built: '
                        f'breakpoint hits {hits!r}')
    return problems, hits, out


def ut_entry(zname):
    """The 16-byte format-4 CRTC entry (ROM $F55) of an UltraTerm
    romset in vendor/mameroms -- the same bytes the card's firmware
    loads, so the expectation is never a copy kept in this file."""
    import zipfile
    with zipfile.ZipFile(os.path.join(ROMS, zname)) as z:
        fw = [n for n in z.namelist() if n.startswith('frm_')][0]
        rom = z.read(fw)
    return list(rom[0xF55:0xF55 + 16])


def run_mame(args, lua_name, lua_body, seconds, dirty=None):
    shutil.rmtree(os.path.join(WORK, 'nvram'), ignore_errors=True)
    # cfg/ persists the natural-keyboard enable flag across runs, which
    # flips the Caps Lock TOGGLE's boot state -- the type-ahead phase's
    # unconditional simulated press then lands in CAPS mode and ed sees
    # 'A' for 'a'. Deterministic alternation, not a flake (docs/MAME.md).
    shutil.rmtree(os.path.join(WORK, 'cfg'), ignore_errors=True)
    lua = os.path.join(WORK, lua_name)
    fill = dirty or os.environ.get('MAUX_DIRTY_FILL')
    if fill:
        pat = ', '.join(map(str, DIRTY_BYTES[fill]))
        lua_body = (DIRTY_PRELUDE.replace('@BANKS@', '16')
                    .replace('@FILL@', pat)) + lua_body
    with open(lua, 'w') as f:
        f.write(lua_body)
    cmd = [MAME, '-rompath', ROMS] + args + [
        '-video', 'none', '-sound', 'none', '-nothrottle',
        '-autoboot_script', lua, '-seconds_to_run', str(seconds)]
    proc = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                          timeout=300)
    return proc.stdout + proc.stderr


def bye_main(play_po, symfile):
    for force, label in ((False, 'a bye round trip as it comes'),
                         (True, 'a bye with a VBL tick forced to be '
                                'latched at TMR_QUIESCE')):
        problems, hits, out = bye_phase(play_po, symfile, force)
        if problems:
            print(out)
            sys.exit(f'[check-mame] FAIL (bye-drain, {label}): ' +
                     '; '.join(problems))
        print(f'[check-mame] PASS: {label} comes back to a working '
              f'shell' + (f' (hits {hits})' if hits else ''))
    return 0


def main():
    play_po, symfile, bye_only = os.path.join(BUILD, 'play.po'), \
        os.path.join(BUILD, 'MAUXPLAY.SYSTEM_Output.txt'), False
    argv = sys.argv[1:]
    while argv:
        a = argv.pop(0)
        if a == '--bye-only':
            bye_only = True
        elif a == '--play':
            play_po = argv.pop(0)
        elif a == '--sym':
            symfile = argv.pop(0)
        else:
            sys.exit(f'usage: check_mame.py [--bye-only] [--play PO] '
                     f'[--sym LISTING]')
    if MAME is None:
        sys.exit('error: mame not on PATH (brew install mame)')
    if not os.path.isdir(ROMS):
        sys.exit('error: vendor/mameroms missing -- '
                 'run `make vendor-mame-roms` first')
    os.makedirs(WORK, exist_ok=True)
    if bye_only:
        return bye_main(play_po, symfile)

    for src, dst in (('maux.po', 'maux.hdv'), ('play.po', 'play.hdv')):
        spath = os.path.join(BUILD, src)
        if not os.path.exists(spath):
            sys.exit(f'error: {spath} missing -- build it first')
        shutil.copyfile(spath, os.path.join(WORK, dst))

    out = run_mame(['apple2ee', '-aux', 'rw3', '-sl4', '', '-sl6', '',
                    '-sl7', 'a2sd', '-hard', 'maux.hdv'],
                   'hello.lua', HELLO_LUA, 20)
    if 'MAUX ALIVE' not in out:
        print(out)
        sys.exit('[check-mame] FAIL: hello boot never showed MAUX ALIVE')
    print('[check-mame] PASS: hello image boots, "MAUX ALIVE" on the '
          'text page')

    def assert_shell(out, label):
        vrows = [l for l in out.splitlines() if l.startswith('VROW')]
        blob = '\n'.join(vrows).lower()
        problems = []
        # The volume root lists BIN (the programs moved there, VROOT),
        # MAUX.SYSTEM and TENANT.SYSTEM; mkdir/grep are under /BIN now.
        for needle, why in (('$ ls', 'echoed command'),
                            ('bin ', 'directory listing'),
                            ('tenant.system', 'directory listing'),
                            ('maux.system', 'directory listing')):
            if needle not in blob:
                problems.append(f'missing {why} ({needle!r})')
        # a prompt on a later row than the echoed command = sh came back
        if blob.count('$ ') < 2:
            problems.append('no fresh prompt after ls exited')
        if problems:
            print(out)
            sys.exit(f'[check-mame] FAIL ({label}): ' +
                     '; '.join(problems))

    out = run_mame(['apple2ee', '-aux', 'rw3', '-sl3', 'ultratermenh',
                    '-sl4', 'mockingboard', '-sl6', '', '-sl7', 'a2sd',
                    '-hard', 'play.hdv'],
                   'play.lua', PLAY_LUA, 45)
    assert_shell(out, 'mockingboard timer')
    print('[check-mame] PASS: play image boots to an interactive shell '
          'on the Mockingboard 6522 timer tier')

    # UT-CELL: the card must be programmed from ITS OWN format-4 entry
    # ($CF55 of whichever firmware is in the slot). Two cards: the
    # updated one (a2ultrme, v3: 9-line cells, 60 Hz) and the ORIGINAL
    # (a2ulttrm, v1: interlaced, 16-line cells, ~30 Hz frames). MAME
    # The mc6845's R0-R11 are read from its save-state items and must
    # equal the ROM entry (R10 & $1F). Height and frame rate (frames
    # against emulated time) are a second check: they depend only on
    # R6 x cell and R0/R4/R5/R8/R9, so R2/R3/R7 are caught only by
    # the register compare. A fixed v3 table fails the v1 row.
    ut_fails = []
    for card, zname, label in (
            ('ultratermenh', 'a2ultrme.zip', 'updated card (v3)'),
            ('ultraterm', 'a2ulttrm.zip', 'ORIGINAL card (v1)')):
        ent = ut_entry(zname)
        cell = ent[9] + (2 if ent[8] & 3 == 3 else 1)
        lines = (ent[4] + 1) * cell + ent[5]
        want_hz = 17430000.0 / (9 * (ent[0] + 1)) / lines
        out = run_mame(['apple2ee', '-aux', 'rw3', '-sl3', card,
                        '-sl4', 'mockingboard', '-sl6', '', '-sl7',
                        'a2sd', '-hard', 'play.hdv'],
                       'sync.lua', SYNC_LUA, 45)
        assert_shell(out, 'UT-CELL ' + label)
        m = re.search(r'UTSYNC frames=(\d+) secs=([\d.]+) height=(\d+)',
                      out)
        if not m:
            print(out)
            sys.exit(f'[check-mame] FAIL (UT-CELL {label}): no UTSYNC')
        rg = re.search(r'UTREGS ([\d ]+)', out)
        want = ent[:12]
        want[10] &= 0x1F
        got = [int(x) for x in rg.group(1).split()] if rg else None
        if got != want:
            ut_fails.append(f'{label}: mc6845 R0-R11 {got} != the ROM '
                            f'format-4 entry {want}')
            continue
        hz = int(m.group(1)) / float(m.group(2))
        if int(m.group(3)) != 24 * cell or abs(hz - want_hz) > want_hz * 0.04:
            ut_fails.append(f'{label}: height {m.group(3)} (want '
                            f'{24 * cell}), {hz:.1f} Hz (want '
                            f"{want_hz:.1f}) -- maux did not program the "
                            f"card's own format-4 entry")
            continue
        print(f'[check-mame] PASS: {label} R0-R11 == its ROM entry, '
              f'synced -- height {m.group(3)}, {hz:.1f} Hz from its own format-4 entry (want '
              f'{want_hz:.1f} Hz)')
    if ut_fails:
        sys.exit('[check-mame] FAIL (UT-CELL): ' + '; '.join(ut_fails))

    out = run_mame(['apple2ee', '-aux', 'rw3', '-sl3', 'ultratermenh',
                    '-sl5', 'mouse', '-sl4', '', '-sl6', '',
                    '-sl7', 'a2sd', '-hard', 'play.hdv'],
                   'play.lua', PLAY_LUA, 45)
    assert_shell(out, 'mouse timer')
    print('[check-mame] PASS: play image boots to an interactive shell '
          'on the AppleMouse VBL tier (real 68705 protocol)')

    # Dirty aux (KFIX11 item 4): the same boot with the RamWorks filled
    # $FF first. MAME's card powers up zeroed, so no stock phase can
    # see an aux-bank read-before-write; on the pre-KFIX11 kernel this
    # phase is red (pid 1's cwd slot, bare `ls` never returns).
    out = run_mame(['apple2ee', '-aux', 'rw3', '-sl3', 'ultratermenh',
                    '-sl5', 'mouse', '-sl4', '', '-sl6', '',
                    '-sl7', 'a2sd', '-hard', 'play.hdv'],
                   'play.lua', PLAY_LUA, 45, dirty='ff')
    assert_shell(out, 'dirty RamWorks, mouse timer')
    print('[check-mame] PASS: play image boots to an interactive shell '
          'on a RamWorks powered up with $FF in every bank')

    # Phase 4: responsiveness during large I/O. The whole ed session is
    # typed in one burst, so most of it arrives while ed's 44KB binary
    # is still loading (interrupts enabled across MLI + the shim's
    # keyboard poll are what keep those keystrokes alive -- the IIe
    # keyboard hardware latches exactly ONE key).
    out = run_mame(['apple2ee', '-aux', 'rw3', '-sl3', 'ultratermenh',
                    '-sl5', 'mouse', '-sl4', '', '-sl6', '',
                    '-sl7', 'a2sd', '-hard', 'play.hdv'],
                   'typeahead.lua', TYPEAHEAD_LUA, 90)
    vrows = [l for l in out.splitlines() if l.startswith('VROW')]
    blob = '\n'.join(vrows).lower()
    problems = []
    if 'midload line' not in blob:
        problems.append('typed-during-load text never reached ed '
                        '(type-ahead lost during the 88-block spawn read)')
    # ls prints in columns, so X is no longer the first word of a row:
    # look for it as a whole word on any row.
    if not any('x' in l.split('[', 1)[1].rstrip('] ').lower().split()
               for l in vrows):
        problems.append("file 'x' missing from ls (ed session died "
                        'mid-flight)')
    if blob.count('$ ') < 2:
        problems.append('no fresh prompt after the session')
    if problems:
        print(out)
        sys.exit('[check-mame] FAIL (type-ahead): ' + '; '.join(problems))
    print('[check-mame] PASS: full ed session typed DURING its own '
          'binary load survives -- keystrokes captured, file written, '
          'shell reprompts')
    bye_main(play_po, symfile)
    print('[check-mame] all green -- maux runs on the second rig, '
          'both interrupt sources, responsive under I/O, and `bye` '
          'survives a latched tick')
    return 0


if __name__ == '__main__':
    sys.exit(main())
