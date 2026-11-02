#!/usr/bin/env python3
"""Build the FULL-VOLUME-DIRECTORY image (`make dirfull-image`).

docs/E2E-COVERAGE.md section 4 item 7: a create that fails because the
VOLUME DIRECTORY is full while the volume still has 1,435 free blocks.
The ProDOS 8 TRM states the rule -- *"$49 Volume directory full ... In
ProDOS 1.0, a volume directory can hold no more than 51 entries"* -- and
nothing in the tree could produce it, because every other fixture either
has room in the root or has no room anywhere.

ONE FIXTURE, TWO KERNELS, OPPOSITE ANSWERS.  Both are built and both are
gated, because the answer is a property of the ProDOS the image carries:

  * **2.4** (`vendor/ProDOS-2.4.bin`, the kernel the Makefile exports as
    PRODOS_kernel_bin and every other gate therefore runs): the wall is
    real.  `mkdir`, `cp` and shell redirection into the root all fail,
    say so, and exit 1; the chain stays 4 blocks at 51 entries.
  * **2.5** (`vendor/ProDOS-2.5.bin`): no wall.  The same three creates
    succeed silently and the volume directory's block chain grows from
    [2, 3, 4, 5] to [2, 3, 4, 5, 165] -- ProDOS allocates a fifth block
    and links it in.

learning:01M07A3XXC1SS5SQYH4CZCPV44 called the 2.5 change out from its
release notes at medium confidence.  This is the measured mechanism, with
the 2.4 control beside it on the same bytes.

MEASURED WRONG FIRST, which is why the pair exists: this builder
originally defaulted to 2.5 while `make` exported 2.4, so the same
fixture "passed" and "failed" within a minute and looked flaky.  It was
not flaky; it was two kernels.  Neither variant may be dropped -- the
2.4 case is the coverage gap item 7 asked for, and the 2.5 case is what
stops the tree from designing against a limit its own vendored
alternative does not have.

A2TIL CANNOT BUILD WHAT PRODOS 2.5 CAN WRITE.  a2til's prodos module
refuses the 52nd root entry (`ValueError: volume directory is full`) --
correct for 2.4, conservative for 2.5.  That asymmetry is what makes the
fixture buildable: the host tool fills the root to exactly the classic
wall, and the guest is the only one that can step past it.

THE CONTROLS STAY IN BOTH.  Each root case has a twin one directory
down, so neither variant can pass by everything failing or everything
succeeding.
"""
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
SYS_BIN = os.path.join(BUILD, 'MAUXE2E.SYSTEM')

#: The two vendored kernels, and the image each one produces. Keyed by
#: the version string check_dirfull.py reports. No default kernel here
#: on purpose: defaulting is what made this look flaky the first time.
VARIANTS = {
    '2.4': os.path.join(BUILD, 'dirfull-24.po'),
    '2.5': os.path.join(BUILD, 'dirfull-25.po'),
}


def kernel_for(version):
    return os.path.join(ROOT, 'vendor', f'ProDOS-{version}.bin')

VOL_BLOCKS = 1600
BOOT_BYTES = 1024
TXT = 0x04
BIN = 0x06
SYS = 0xFF
LOAD_AUX = 0x0800
SYS_AUX = 0x2000

#: The CLASSIC wall: 4 volume-directory blocks, 12 entries in the key
#: block (slot 0 is the header) plus 13 in each of the other three.
#: This is where the image starts, not where it ends -- see the header.
VOLDIR_ENTRIES = 51

#: Volume-directory blocks a fresh volume has, and the length this
#: image's chain must still be when it is handed to the emulator.
VOLDIR_BLOCKS = 4

TOOLS = ['sh', 'echo', 'mkdir', 'cp']
CAPTURES = ['ST', 'MKNF', 'MKOK', 'CPNF', 'CPOK']

ROOTDIR = '/mnt/MAUX'
IMG_DIR = f'{ROOTDIR}/E2E'
DF_DIR = f'{ROOTDIR}/DF'

CPSRC_TEXT = 'rootgrow copy source\n'

SCRIPT_LINES = [
    'CD /mnt/MAUX',
    # -- The root holds 51 entries, the classic ProDOS wall. Every one
    # -- of these asks for a 52nd, 53rd, 54th NAME in it.
    'MKDIR /mnt/MAUX/DFNEW >> /mnt/MAUX/E2E/MKNF 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    # -- The control: the same mkdir one directory down, where nothing
    # -- was ever in question. A green run must be the root GROWING,
    # -- not everything succeeding everywhere.
    'MKDIR /mnt/MAUX/DF/SUBNEW >> /mnt/MAUX/E2E/MKOK 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'CP /mnt/MAUX/DF/CPSRC /mnt/MAUX/DFCOPY >> /mnt/MAUX/E2E/CPNF 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'CP /mnt/MAUX/DF/CPSRC /mnt/MAUX/DF/CPCOPY >> /mnt/MAUX/E2E/CPOK 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    # -- sh's own `>` CREATE lands in the root too, and it happens in
    # -- the SHELL rather than a child (docs/PROCIO.md sec 4a), so this
    # -- line exercises a different caller of the same MLI CREATE.
    'ECHO REDIR > /mnt/MAUX/DFOUT',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'EXIT',
]


def image_text(text):
    return convert.text_from_host(text.encode('ascii'), high_bit=True)


CPSRC_BYTES = image_text(CPSRC_TEXT)
SCRIPT_BYTES = image_text(''.join(line + '\n' for line in SCRIPT_LINES))

#: Names the guest creates PAST the classic 51-entry wall, and the
#: twins one directory down that were never in doubt.
#: Spelled WITHOUT the volume name, because that is how check_rootgrow.py
#: keys its poststate dicts -- a2til resolves both spellings, so a
#: mismatch here is not an error, it is a lookup that silently checks
#: nothing. The host selftest caught exactly that: '/mnt/MAUX/DF/SUBNEW'
#: here against '/DF/SUBNEW' there let "the control never got created"
#: pass as a green run.
GROWN_AFTER = ['/DFNEW', '/DFCOPY', '/DFOUT']
PRESENT_AFTER = ['/DF/SUBNEW', '/DF/CPCOPY']


def voldir_chain(path):
    """The volume directory's block chain, walked from block 2 through
    each block's `next` pointer.  Read from the raw image rather than
    through a2til, because whether the chain GREW is exactly what a2til
    would never produce itself."""
    chain, seen, blk = [], set(), 2
    with open(path, 'rb') as f:
        while blk and blk not in seen:
            seen.add(blk)
            chain.append(blk)
            f.seek(blk * 512)
            block = f.read(512)
            if len(block) < 4:
                break
            blk = struct.unpack('<H', block[2:4])[0]
    return chain


def stage_txt(vol, path, data=b''):
    vol.write_file(path, data, file_type=TXT, aux_type=0, overwrite=True)


def root_entries(vol):
    return sum(1 for _ in vol.scandir('/'))


def fill_root(vol):
    """Pad the volume directory to its last slot.  One block each -- the
    entries are what is scarce here, not the space."""
    pads = []
    while root_entries(vol) < VOLDIR_ENTRIES:
        name = f'{ROOTDIR}/PAD{len(pads):02d}'
        stage_txt(vol, name, image_text('pad\n'))
        pads.append(name)
    return pads


def build(version, kernel_bin, out_img):
    missing = []
    for path, label in ([(CARRIER_IMG, 'carrier volume'),
                         (kernel_bin, 'vendored ProDOS kernel'),
                         (SYS_BIN, 'MAUXE2E.SYSTEM')]
                        + [(os.path.join(BUILD, f'{t}.bin'), f'{t} binary')
                           for t in TOOLS]):
        if not os.path.exists(path):
            missing.append(f'{label}: {path}')
    if missing:
        for m in missing:
            print(f'error: missing {m}', file=sys.stderr)
        return 2

    prodos.create(out_img, name=CARRIER_VOL, blocks=VOL_BLOCKS)
    with open(CARRIER_IMG, 'rb') as f:
        boot = f.read(BOOT_BYTES)
    if len(boot) != BOOT_BYTES or boot == bytes(BOOT_BYTES):
        print(f'error: {CARRIER_IMG} has no boot block to copy',
              file=sys.stderr)
        return 2
    with open(out_img, 'r+b') as f:
        f.write(boot)

    vol = prodos.Volume(out_img)
    try:
        with open(kernel_bin, 'rb') as f:
            kernel = f.read()
        with open(SYS_BIN, 'rb') as f:
            system = f.read()
        vol.write_file('/PRODOS', kernel, file_type=SYS,
                       aux_type=SYS_AUX, overwrite=True)
        vol.write_file('/MAUX.SYSTEM', system, file_type=SYS,
                       aux_type=SYS_AUX, overwrite=True)

        vol.mkdir('/BIN')
        sizes, shas = {}, {}
        for tool in TOOLS:
            path = os.path.join(BUILD, f'{tool}.bin')
            with open(path, 'rb') as f:
                data = f.read()
            sizes[tool] = len(data)
            shas[tool] = hashlib.sha256(data).hexdigest()[:12]
            vol.write_file(f'/BIN/{tool.upper()}', data, file_type=BIN,
                           aux_type=LOAD_AUX, overwrite=True)

        for path in ('/E2E', '/DF'):
            vol.mkdir(path)
        stage_txt(vol, '/E2E/SCRIPT', SCRIPT_BYTES)
        for name in CAPTURES:
            stage_txt(vol, f'/E2E/{name}')
        stage_txt(vol, '/DF/CPSRC', CPSRC_BYTES)

        before = root_entries(vol)
        pads = fill_root(vol)
        entries, free, total = root_entries(vol), vol.free_blocks, \
            vol.total_blocks
        # The 52nd name must be refused by the library too -- if it is
        # not, this image is not in the state the gate is named for.
        try:
            stage_txt(vol, f'{ROOTDIR}/OVERFLOW', image_text('no\n'))
        except (ValueError, OSError) as exc:
            # a2til's refusal was ValueError historically and is
            # OSError(ENOSPC) since its errno-typed-exception polish
            # (a2til c57ac62) -- accept both; the FACT under test is
            # the refusal, not its Python spelling (2026-09-01).
            refusal = str(exc)
        else:
            print(f'[build-dirfull] {version}: FAIL: the root accepted a 52nd entry -- '
                  'this image does not have a full volume directory',
                  file=sys.stderr)
            return 1
    finally:
        vol.close()

    print(f'[build-dirfull] {version}: {version}: carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-dirfull] {version}: MAUX.SYSTEM {len(system)}B '
          f'{hashlib.sha256(system).hexdigest()[:12]}')
    for t in TOOLS:
        print(f'[build-dirfull] {version}:   {t:6} {sizes[t]:6}B  sha256:{shas[t]}')
    print(f'[build-dirfull] {version}: staged script {len(SCRIPT_LINES)} lines; '
          f'longest line {max(len(line) for line in SCRIPT_LINES)} chars')
    print(f'[build-dirfull] {version}: root entries: {before} staged + {len(pads)} pad '
          f'= {entries} of {VOLDIR_ENTRIES}')
    print(f'[build-dirfull] {version}: host library refused the 52nd: {refusal} '
          f'(correct for <=2.4, conservative for 2.5 -- see the header)')
    chain = voldir_chain(out_img)
    print(f'[build-dirfull] {version}: volume-directory chain at build time: {chain}')
    print(f'[build-dirfull] {version}: free blocks {free} of {total} -- the volume has '
          f'room; the question this image asks is whether the DIRECTORY does')
    if len(chain) != VOLDIR_BLOCKS:
        print(f'[build-dirfull] {version}: FAIL: chain is {len(chain)} blocks, expected '
              f'{VOLDIR_BLOCKS} before the guest runs', file=sys.stderr)
        return 1
    if entries != VOLDIR_ENTRIES:
        print(f'[build-dirfull] {version}: FAIL: root holds {entries} entries, expected '
              f'{VOLDIR_ENTRIES}', file=sys.stderr)
        return 1
    if free <= 0:
        print(f'[build-dirfull] {version}: FAIL: no free blocks left -- a full volume '
              'would mask the full-directory failure this image is for',
              file=sys.stderr)
        return 1
    print(f'[build-dirfull] {version}: {out_img} ready '
          f'({os.path.getsize(out_img)} bytes)')
    return 0


def main():
    rc = 0
    for version, out_img in sorted(VARIANTS.items()):
        r = build(version, kernel_for(version), out_img)
        if r:
            rc = r
    return rc


if __name__ == '__main__':
    raise SystemExit(main())
