#!/usr/bin/env python3
"""vendor_mame_roms.py -- assemble the MAME romsets that boot maux on the
SECOND emulator rig (docs/MAME.md) into vendor/mameroms/, following the
"vendor, never commit" rule (vendor/ is gitignored).

Almost everything MAME needs is already on disk in byte-identical form
under ~/src/verilogapple/sim/roms/ -- verified by CRC32/SHA1 against
`mame -listroms` on 2026-08-18, so this script mostly RENAMES:

  apple2ee.zip   342-0304-a.e10 / 342-0303-a.e8  = iie_cd_ef.rom halves
                 342-0265-a.chr                  = iie_video.rom
                 341-0132-d.e12                  = keyboard layout ROM
                                                   (downloaded, pinned)
  a2ultrme.zip   frm_b5c9.bin  = ultraterm/firmware_v3.bin
                 chs_5604.bin  = ultraterm/chargen_v3.bin
                 ult_251c.jed  = ultraterm/pal_u4_v3.jed
  a2ulttrm.zip   frm_b537.bin  = ultraterm/firmware_v1.bin   (the
                 chs_7859.bin  = ultraterm/chargen_v1.bin     ORIGINAL
                 ult_2a313.jed = ultraterm/pal_u4_v1.jed      card)
  a2sd.zip       appleiisd.bin = AppleIISd firmware (GPL, downloaded
                                 from the author's repo, pinned)
  votrsc01a.zip  sc01a.bin     = 512-byte PLACEHOLDER (zeros). The
                 Mockingboard config pulls in a Votrax SC-01 speech chip
                 maux never touches; MAME runs with a wrong-checksum file
                 (warns) but refuses a missing one.

Downloads (sha256-pinned; skipped when cached in vendor/):
  AppleIISd.bin  https://raw.githubusercontent.com/freitz85/AppleIISd/
                 master/Binary/AppleIISd.bin
  keyboard ROM   https://downloads.reactivemicro.com/Apple%20II%20Items/
                 ROM_and_JEDEC/IIe/Keyboard%20ROM/Apple%20IIe%20Keyboard
                 %20-%20342-0132-D%20-%202716.bin
                 (MAME names the same dump 341-0132-d; hashes match its
                 expectation exactly.)

Usage: python3 scripts/vendor_mame_roms.py
Env overrides:
  VERILOGAPPLE   -- verilogapple checkout (default ~/src/verilogapple)
  MAMEROM_DIR    -- output directory (default vendor/mameroms)
"""
import hashlib
import os
import sys
import urllib.request
import zipfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VA = os.environ.get('VERILOGAPPLE',
                    os.path.expanduser('~/src/verilogapple'))
OUT = os.environ.get('MAMEROM_DIR', os.path.join(ROOT, 'vendor', 'mameroms'))
CACHE = os.path.join(ROOT, 'vendor')

_MOUSE_BASE = ('https://mirrors.apple2.org.za/Apple%20II%20Documentation'
               '%20Project/Interface%20Cards/Digitizers/'
               'Apple%20Mouse%20Interface%20Card/ROM%20Images/')

DOWNLOADS = {
    'AppleIISd.bin': (
        'https://raw.githubusercontent.com/freitz85/AppleIISd/master/'
        'Binary/AppleIISd.bin',
        '595e4022ccf0f8d8bd982015f704ee177a88713ff2a8033d8fd33bf5573108fc'),
    'kbd_342-0132-D.bin': (
        'https://downloads.reactivemicro.com/Apple%20II%20Items/'
        'ROM_and_JEDEC/IIe/Keyboard%20ROM/'
        'Apple%20IIe%20Keyboard%20-%20342-0132-D%20-%202716.bin',
        'a1989da84ea4381d309e7e08783771f884e913236b9bcc71c3d649aacf76537a'),
    # AppleMouse card: the 68705P3 MCU's internal mask ROM (the piece
    # that makes MAME's a2mouse run the REAL command protocol) plus the
    # PAL dumps, from the same mirror family vendor_prodos/vendor_merlin
    # already trust. The $Cn00 firmware ROM (341-0270) is NOT downloaded
    # -- verilogapple's applemouse.rom is byte-identical (SHA1 verified).
    '341-0269.2b': (
        _MOUSE_BASE + '341-0269.2b',
        '66480812edad5f6bd70349949cf8bd8fbafee2dc8bf396541d4e78bac2629ec0'),
    'mmi_pal16r4a_jedec.2a': (
        _MOUSE_BASE + 'mmi_pal16r4a%28jedec%29.2a',
        '0af675986b455ce10236e9a98bd73fd226474db75c2139560f31a6ff807a890e'),
    'mmi_pal16r4a_binary.2a': (
        _MOUSE_BASE + 'mmi_pal16r4a%28binary%29.2a',
        '47b367e4bd75bb14867d287ff62f53ec515d35aaf66d4b357bb5c5be31704480'),
}

# name-in-zip -> expected CRC32 (from `mame -listroms`, 2026-08-18)
EXPECT = {
    ('apple2ee.zip', '342-0304-a.e10'): 0x443aa7c4,
    ('apple2ee.zip', '342-0303-a.e8'): 0x95e10034,
    ('apple2ee.zip', '342-0265-a.chr'): 0x2651014d,
    ('apple2ee.zip', '341-0132-d.e12'): 0xc506efb9,
    ('a2ultrme.zip', 'frm_b5c9.bin'): 0xb71e05e0,
    ('a2ultrme.zip', 'chs_5604.bin'): 0x3fb4e90a,
    ('a2ultrme.zip', 'ult_251c.jed'): 0x12fabb0d,
    ('a2ulttrm.zip', 'frm_b537.bin'): 0x1e85a93e,
    ('a2ulttrm.zip', 'chs_7859.bin'): 0xebe8f333,
    ('a2ulttrm.zip', 'ult_2a313.jed'): 0xdcd51dea,
    ('a2sd.zip', 'appleiisd.bin'): 0xe82eea8a,
    ('a2mouse.zip', '341-0270-c.4b'): 0x0bcd1e8e,
    ('a2mouse.zip', '341-0269.2b'): 0x94067f16,
    ('a2mouse.zip', 'mmi_pal16r4a,jedec.2a'): 0x1d620ee5,
    ('a2mouse.zip', 'mmi_pal16r4a,binary.2a'): 0x1da5c745,
}


def fetch(name):
    url, want = DOWNLOADS[name]
    path = os.path.join(CACHE, name)
    if os.path.exists(path):
        data = open(path, 'rb').read()
        if hashlib.sha256(data).hexdigest() == want:
            return data
        print(f'[vendor-mame] cached {name} hash mismatch, refetching')
    print(f'[vendor-mame] fetching {name}')
    data = urllib.request.urlopen(url).read()
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        sys.exit(f'error: {name} sha256 {got}, expected {want}')
    os.makedirs(CACHE, exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    return data


def va_rom(rel):
    path = os.path.join(VA, 'sim', 'roms', rel)
    if not os.path.exists(path):
        sys.exit(f'error: {path} missing -- is verilogapple checked out '
                 f'with its ROMs populated?')
    return open(path, 'rb').read()


def main():
    os.makedirs(OUT, exist_ok=True)
    cd_ef = va_rom('iie_cd_ef.rom')
    if len(cd_ef) != 16384:
        sys.exit('error: iie_cd_ef.rom is not 16K')

    sets = {
        'apple2ee.zip': {
            '342-0304-a.e10': cd_ef[:8192],
            '342-0303-a.e8': cd_ef[8192:],
            '342-0265-a.chr': va_rom('iie_video.rom'),
            '341-0132-d.e12': fetch('kbd_342-0132-D.bin'),
        },
        'a2ultrme.zip': {
            'frm_b5c9.bin': va_rom('ultraterm/firmware_v3.bin'),
            'chs_5604.bin': va_rom('ultraterm/chargen_v3.bin'),
            'ult_251c.jed': va_rom('ultraterm/pal_u4_v3.jed'),
        },
        'a2ulttrm.zip': {
            'frm_b537.bin': va_rom('ultraterm/firmware_v1.bin'),
            'chs_7859.bin': va_rom('ultraterm/chargen_v1.bin'),
            'ult_2a313.jed': va_rom('ultraterm/pal_u4_v1.jed'),
        },
        'a2sd.zip': {
            'appleiisd.bin': fetch('AppleIISd.bin'),
        },
        'a2mouse.zip': {
            '341-0270-c.4b': va_rom('applemouse.rom'),
            '341-0269.2b': fetch('341-0269.2b'),
            'mmi_pal16r4a,jedec.2a': fetch('mmi_pal16r4a_jedec.2a'),
            'mmi_pal16r4a,binary.2a': fetch('mmi_pal16r4a_binary.2a'),
        },
        # The M68705P3 CPU device also wants the part's generic
        # programming-mode bootstrap ROM (115 bytes). It never executes
        # in normal emulation (bootstrap mode is for EPROM programming),
        # and no dump is in our sources -- a zero placeholder satisfies
        # MAME (wrong-checksum warning; a MISSING file would be fatal).
        'm68705p3.zip': {
            'bootstrap.bin': bytes(115),
        },
        'votrsc01a.zip': {
            'sc01a.bin': bytes(512),   # placeholder; see module docstring
        },
    }

    for zname, members in sets.items():
        for mname, data in members.items():
            want = EXPECT.get((zname, mname))
            if want is not None:
                got = zlib.crc32(data) & 0xFFFFFFFF
                if got != want:
                    sys.exit(f'error: {zname}/{mname} crc {got:08x}, '
                             f'MAME expects {want:08x}')
        zpath = os.path.join(OUT, zname)
        with zipfile.ZipFile(zpath, 'w') as z:
            for mname, data in members.items():
                z.writestr(mname, data)
        print(f'[vendor-mame] wrote {zpath} '
              f'({", ".join(sorted(members))})')
    print('[vendor-mame] romsets ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
