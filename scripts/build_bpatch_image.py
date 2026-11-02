#!/usr/bin/env python3
"""Build build/bpatch.po -- the check-bpatch gate image (spec-driven
binary patcher).

The play image (which stages `bpatch`, `cmp` and `sh`) plus /mnt/MAUX/B,
holding SYNTHETIC fixtures -- no copyrighted bytes, just a crafted blob
that exercises every bpatch directive and both flip-lc guards:

  T      the 24-byte target. Three real read-ROM language-card switches
         to flip, plus two CONTROLS that must NOT flip:
           0: AD 81 C0  LDA $C081  (read ROM)  -> AD 83 C0
           3: 2C 82 C0  BIT $C082             -> 2C 80 C0
           6: 8D 81 C0  STA $C081             -> 8D 83 C0
           9: AD 81 C1  high byte is C1, not C0 -> UNCHANGED ($C0 guard)
          12: EA 82 C0  opcode EA, not AD/2C/8D -> UNCHANGED (opcode guard)
          15: 55        a plain byte, the expect/set target
          16..23: 00    filler
  EXP    T after SPEC: flips at 0/3/6, controls at 9/12 intact, byte 15
         set to EE.
  TORIG  a pristine copy of T, for the refuse case.
  SPEC   `expect 0F 55` / `set 0F EE` / `flip-lc`.
  SPECBAD `expect 0F 99` (wrong) / `set 0F EE` -- must make bpatch EXIT
         1 and write NOTHING, so a second target stays == TORIG.

check_bpatch.py stages a second target T2 (== T) that SPECBAD is run
against. Spec files are maux text (high-bit ASCII, $8D newlines);
bpatch masks bit 7 as it reads them.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'bpatch.po')
BPATCH_BIN = os.path.join(ROOT, 'build', 'bpatch.bin')
VOL = 'MAUX'
SUBDIR = f'/mnt/{VOL}/B'

T_BYTES = bytes([
    0xAD, 0x81, 0xC0,   # 0  flip -> 83
    0x2C, 0x82, 0xC0,   # 3  flip -> 80
    0x8D, 0x81, 0xC0,   # 6  flip -> 83
    0xAD, 0x81, 0xC1,   # 9  control: high byte C1, no flip
    0xEA, 0x82, 0xC0,   # 12 control: opcode EA, no flip
    0x55,               # 15 expect/set target
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   # 16..23
])
_exp = bytearray(T_BYTES)
_exp[1] = 0x83
_exp[4] = 0x80
_exp[7] = 0x83
_exp[15] = 0xEE
EXP_BYTES = bytes(_exp)


def hitext(lines):
    """maux text: each char high-bit-set, each line $8D-terminated."""
    out = bytearray()
    for ln in lines:
        out += bytes(ord(c) | 0x80 for c in ln)
        out += b'\x8d'
    return bytes(out)


SPEC = hitext(['# bpatch gate spec', 'expect 0F 55', 'set 0F EE', 'flip-lc'])
SPECBAD = hitext(['expect 0F 99', 'set 0F EE'])


def main():
    for path, label in [(PLAY_IMG, 'play image'), (BPATCH_BIN, 'bpatch.bin')]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    shutil.copyfile(PLAY_IMG, OUT_IMG)
    with open(BPATCH_BIN, 'rb') as f:
        bpbin = f.read()
    prodos.mount(OUT_IMG)
    try:
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/bpatch', bpbin, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.mkdir(SUBDIR)
        for name, data, ftype in (
                ('T', T_BYTES, 0x06), ('T2', T_BYTES, 0x06),
                ('TORIG', T_BYTES, 0x06), ('EXP', EXP_BYTES, 0x06),
                ('SPEC', SPEC, 0x04), ('SPECBAD', SPECBAD, 0x04)):
            prodos.write(f'{SUBDIR}/{name}', data, file_type=ftype,
                         aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(SUBDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-bpatch] wrote {SUBDIR} fixtures {names}')
    print(f'[build-bpatch] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
