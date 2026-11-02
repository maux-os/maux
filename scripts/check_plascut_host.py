#!/usr/bin/env python3
"""Host checks for verified, opt-in native restore boundaries.

Uses the actual compiler-produced fixtures. The emulator gate separately
executes mutable globals/native code over warm launches and compares NAS
outputs with merlin32. Run after make build/nas.cut build/cookt.cut.
"""
from pathlib import Path
import struct
import tempfile
import unittest

from plascut import Cooker, CookError, Image, LOAD_BASE, ROOT, cook, dci, r16

BUILD = Path(ROOT) / 'build'


def load(name, immutable=(), search=None, const=()):
    img = Image((BUILD / 'plasma.bin').read_bytes(),
                (BUILD / 'rt.mod').read_bytes())
    ck = Cooker(img, search or [str(BUILD)], const, immutable)
    ck.loadmod(name)
    return ck


def esd_entries(b):
    p = 2 + r16(b, 0)
    while b[p]:
        p += 4
    p += 1
    entries = []
    while b[p]:
        start = p
        name, p = dci(b, p)
        entries.append((name, start, p, p + 3))
        p += 3
    return entries


class RestoreBoundaryTests(unittest.TestCase):
    def test_nas_recovery_and_identical_loaded_program(self):
        old = load('NAS', const=('NAS',))
        new = load('NAS', immutable=('nas',), const=('nas',))
        # All relocated executable/data bytes are unchanged before finish
        # patches the heap/restore-table pointers in the runtime header.
        self.assertEqual(old.img.heap, new.img.heap)
        self.assertEqual(old.img.buf, new.img.buf)
        native = new.loaded[-1][4] - new.symtab['CKDATAEND']
        self.assertGreater(native, 0)
        old_end, _, _, old_copies = old.finish('NAS')
        new_end, _, _, new_copies = new.finish('NAS')
        self.assertEqual(old_end - new_end, native)
        self.assertEqual(old_copies[-1][2] - new_copies[-1][2], native)
        self.assertEqual(old_copies[:-1], new_copies[:-1])
        self.assertEqual(new_copies[-1][0] + new_copies[-1][2],
                         new.symtab['CKDATAEND'])
        print(f'[check-plascut-host] NAS saves {native} B; cooked '
              f'{old_end - LOAD_BASE} -> {new_end - LOAD_BASE} B; '
              f'NAS restore {old_copies[-1][2]} -> {new_copies[-1][2]} B')

    def test_mutable_native_and_default_restore(self):
        old = load('COOKT')
        new = load('COOKT', ('COOKT',))
        start = new.loaded[-1][3]
        mark = new.symtab['CKDATAEND']
        bytecode = new.loaded[-1][4]
        # Independent native oracle: DEX / LDA #42 / STA $C0,X /
        # LDA #0 / STA $A0,X / RTS. Only this helper can be excluded.
        native = bytes.fromhex('ca a9 2a 95 c0 a9 00 95 a0 60')
        # xplasm emits a zero PAD BYTE before _SUBSEG in this fixture.
        actual = bytes(new.img.buf[new.img.off(mark):new.img.off(bytecode)])
        self.assertEqual(actual, native + b'\x00')
        self.assertEqual(new.datasegs[-1][:2], (start, 2 + len(native)))
        self.assertEqual(old.datasegs[-1][:2], (start, bytecode - start))
        _, _, _, copies = new.finish('COOKT')
        dst, src, n, _ = copies[-1]
        self.assertEqual(new.img.r16(src), 0)  # runs
        self.assertEqual(new.img.r8(src + 4), 0)  # mutable LDA operand
        self.assertEqual(dst + n, mark)

    def rejected(self, b, name='COOKT', const=()):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / (name.lower() + '.mod')).write_bytes(b)
            with self.assertRaises(CookError):
                ck = load(name, (name,), [tmp, str(BUILD)], const)
                ck.finish(name)

    def test_missing_or_duplicate_local_export(self):
        b = bytearray((BUILD / 'cookt.mod').read_bytes())
        _, start, flag, end = next(e for e in esd_entries(b)
                                   if e[0] == 'CKDATAEND')
        missing = bytearray(b)
        missing[start] ^= 1
        self.rejected(missing)
        self.rejected(b[:end] + b[start:end] + b[end:])
        # A same-named export from the runtime/dependency cannot stand in
        # for a local marker (global lookup was a tempting unsafe shortcut).
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'cookt.mod').write_bytes(missing)
            # No opt-in: a module with mutable native code and no marker
            # remains supported and receives the complete restore copy.
            plain = load('COOKT', search=[tmp])
            self.assertEqual(plain.datasegs[-1][1],
                             plain.loaded[-1][4] - plain.loaded[-1][3])
            img = Image((BUILD / 'plasma.bin').read_bytes(),
                        (BUILD / 'rt.mod').read_bytes())
            ck = Cooker(img, [tmp], immutable_native=('COOKT',))
            ck.symtab['CKDATAEND'] = 0x405D
            with self.assertRaises(CookError):
                ck.loadmod('COOKT')

    def test_invalid_boundaries(self):
        b = bytearray((BUILD / 'cookt.mod').read_bytes())
        flag = next(e[2] for e in esd_entries(b) if e[0] == 'CKDATAEND')
        for val in (0, 0xFFFF, r16(b, 6), r16(b, 6) + 1):
            with self.subTest(boundary=val):
                bad = bytearray(b)
                struct.pack_into('<H', bad, flag + 1, val)
                self.rejected(bad)
        # A native boundary inside/before the const-prefix mutable marker
        # would omit globals even though it is inside the module's image.
        nas = bytearray((BUILD / 'nas.mod').read_bytes())
        flag = next(e[2] for e in esd_entries(nas) if e[0] == 'CKDATAEND')
        ck = load('NAS', const=('NAS',))
        module_addr = ck.loaded[-1][3]
        modofst = ck.loaded[-1][4] - r16(nas, 6)
        for addr in (module_addr, ck.datasegs[-1][0] + 3):
            bad = bytearray(nas)
            struct.pack_into('<H', bad, flag + 1, addr - modofst)
            self.rejected(bad, 'NAS', ('NAS',))

    def test_unloaded_opt_in_refused(self):
        ck = load('COOKT', ('TYPO',))
        with self.assertRaisesRegex(CookError, 'not loaded: TYPO'):
            ck.finish('COOKT')

    def test_refusal_does_not_overwrite_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'prior.cut'
            out.write_bytes(b'previous valid image')
            with self.assertRaises(CookError):
                cook('COOKT', [str(BUILD)], BUILD / 'plasma.bin',
                     BUILD / 'rt.mod', out, verbose=False,
                     immutable_native=('TYPO',))
            self.assertEqual(out.read_bytes(), b'previous valid image')


if __name__ == '__main__':
    unittest.main()
