#!/usr/bin/env python3
"""Patch Apple's EDASM to run headless under maux's proshim.

    python3 scripts/patch_edasm.py EDASM.DSK OUTDIR

Reads EDASM's four files (SYSTEM/ED/ASM/SWAP) from a user-supplied
EDASM disk image and writes PATCHED copies to OUTDIR. EDASM's own bytes
are Apple's and are never committed to this tree -- this script is the
patch, applied to a disk you already have.

What the patch does, and why (measured on verilogapple, docs/EDASM-
SHIM.md P3; learning:01M1XAAWCC4GR1VJTHA30D1P52):

EDASM is not the "well-behaved" ProDOS program it looks like -- it
reads the real ROM directly, drives the //e 80-column firmware, and
owns CSW/KSW for its own I/O redirection. proshim hosts a tenant that
uses the STANDARD monitor via the hooks; EDASM does not. Two edits fix
that.

1. Every part: read-ROM language-card switches -> read-RAM, so EDASM
   sees proshim's copied monitor (in LC RAM, console redirected to fd)
   instead of the real ROM:
     LDA/BIT/STA $C081 -> $C083   (read ROM -> read RAM, write RAM)
     LDA/BIT/STA $C082 -> $C080   (read ROM -> read RAM, write-prot)

2. EDASM.ED, five bytes, to defeat its 80-column detection and point
   its console default at the monitor leaves proshim redirects to fd:
     $A75C  $C3->$00  : the 80-col detector always returns "none"
     $A7E1  $D9->$F0  }
     $A7E3  $B3->$FD  } default console CSW = $FDF0 (proshim's fd 1)
     $A7E9  $24->$1B  }
     $A7ED  $A6->$FD  } default console KSW = $FD1B (proshim's fd 0)

Then stage the patched files in one directory on a maux volume beside
the proshim binary and run `proshim /vol/dir/EDASM.SYSTEM` -- EDASM
boots to its `:` prompt with its console on the pipe. `< cmds > log`
drives it headless.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

PARTS = ('EDASM.SYSTEM', 'EDASM.ED', 'EDASM.ASM', 'EDASM.SWAP')


def flip_lc(d):
    """Rewrite read-ROM LC switches to read-RAM. Returns the count."""
    n = 0
    for i in range(len(d) - 2):
        if d[i] in (0xAD, 0x2C, 0x8D) and d[i + 2] == 0xC0:
            if d[i + 1] == 0x81:
                d[i + 1] = 0x83
                n += 1
            elif d[i + 1] == 0x82:
                d[i + 1] = 0x80
                n += 1
    return n


ED_CONSOLE = [(0xA75C, 0xC3, 0x00), (0xA7E1, 0xD9, 0xF0),
              (0xA7E3, 0xB3, 0xFD), (0xA7E9, 0x24, 0x1B),
              (0xA7ED, 0xA6, 0xFD)]


def read_part(root, name):
    """Find EDASM.<name> anywhere under the volume root."""
    def walk(path):
        for e in prodos.scandir(path):
            p = f'{path}/{e.name}'
            if e.is_dir():
                yield from walk(p)
            elif e.name.upper() == name:
                yield p
    hits = list(walk(root))
    if not hits:
        raise FileNotFoundError(f'{name} not found under {root}')
    return prodos.read(hits[0])


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    disk, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    prodos.mount(disk, readonly=True)
    try:
        root = '/' + prodos.mounts()[0]
        parts = {n: bytearray(read_part(root, n)) for n in PARTS}
    finally:
        for vol in list(prodos.mounts()):
            prodos.unmount(vol)
    for name, d in parts.items():
        n = flip_lc(d)
        extra = ''
        if name == 'EDASM.ED':
            for addr, want, new in ED_CONSOLE:
                off = 0x1000 + (addr - 0x9900)   # ED[$1000:] runs at $9900
                if d[off] != want:
                    print(f'warning: {name} ${addr:04X} is '
                          f'${d[off]:02X}, expected ${want:02X} -- '
                          f'wrong EDASM version?', file=sys.stderr)
                d[off] = new
            extra = ' + 5 console bytes'
        open(os.path.join(outdir, name), 'wb').write(d)
        print(f'{name}: LC read-ROM->read-RAM x{n}{extra}')
    print(f'patched EDASM written to {outdir}/')
    return 0


if __name__ == '__main__':
    sys.exit(main())
