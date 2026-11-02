#!/usr/bin/env python3
"""split_kseg.py -- cut the kernel cold segment off a freshly assembled
kernel .SYSTEM image (docs/KSEG.md "The file").

WHY. A manifest that carries a segment (today: only src/test/playtest.s,
via inc/mm.hw.equ's `]KSEG_WANT` override) assembles the segment's
modules under `org KSEG_ORG` ($D400) as the LAST thing in the put chain,
after the label `KSEG_LOW` and before `KSEG_END`. merlin32 lays a
mid-file `org` block CONTIGUOUSLY in the flat output (measured,
learning:01M2MD0W7MY4V04SNT3E60WMHF), so the raw file merlin32 writes is
[flat part][segment part] back to back -- oversized by the segment's own
length. This script splits that raw file at the KSEG_LOW boundary: the
flat part becomes the real `.SYSTEM` (unchanged from a no-segment build,
same load window the harnesses' result cells sit above), and the segment
part becomes a sibling `_KSEG` file, staged separately by the per-image
build script (never `putbin`'d into the `.SYSTEM` -- that would let
ProDOS's own load overwrite the harness's poked result cells, exactly
the failure the parked /dev branch hit; see docs/KSEG.md "Why not a
separate file").

WHERE THE ADDRESSES COME FROM. merlin32 -v1 writes a `<name>_Output.txt`
symbol dump beside the binary (a plain `NAME = $HEXVALUE` table at the
end of the file, checked here rather than the manifest source: KSEG_LOW
and KSEG_END are LABELS, not `equ` constants, so they never appear as
`equ $XXXX` text in the source the way check_kernel_images.py's other
constants do -- their address only exists once the assembler resolves
it). A manifest with no segment never emits either symbol; that is the
assemble-time no-op case and this script is silent success on it (no
`_KSEG` file, `.SYSTEM` untouched).

USAGE. `split_kseg.py` with no arguments processes every kernel image
this tree knows about (derive_kernel_images(), the same derivation
check_kernel_images.py uses); `split_kseg.py NAME` processes one image
by its built basename (e.g. `MAUXPLAY.SYSTEM` or `MAUXPLAY`). Exits
nonzero -- a BUILD FAILURE, not a warning -- if a found segment is empty
or exceeds KSEG_MAXPG*256 (3072) bytes, or if the file's own length
disagrees with KSEG_LOW/KSEG_END's arithmetic (a programming error in
the manifest, not a normal outcome).
"""
import glob
import os
import re
import sys

import check_manifests as cm
import check_kernel_images as cki

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')

SYM_RE_TEMPLATE = r'^\s*{name}\s*=\s*\$([0-9A-Fa-f]+)\s*$'
LSEG_MAXPG = 8   # inc/mm.lseg.equ LSEG_MAXPG -- $1300-$1AFF.
KSEG_MAXPG = 12  # inc/mm.hw.equ KSEG_MAXPG -- 3072 B, the hardware
                 # ceiling ($D400-$DFFF).


def _read_symbol(output_txt, name):
    regex = re.compile(SYM_RE_TEMPLATE.format(name=re.escape(name)),
                        re.MULTILINE)
    with open(output_txt, encoding='ascii', errors='replace') as fh:
        text = fh.read()
    m = regex.search(text)
    return int(m.group(1), 16) if m else None


def split_one(sys_path, manifest_path):
    """sys_path: build/<NAME>.SYSTEM (already built by merlin32 -v1).
    manifest_path: the top-level .s manifest that produced it. Returns
    True if a segment was cut, False if this image carries none (both
    are success -- see module docstring)."""
    output_txt = sys_path + '_Output.txt'
    if not os.path.exists(sys_path):
        print(f'[split-kseg] SKIP {os.path.basename(sys_path)}: not built')
        return False
    if not os.path.exists(output_txt):
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: no '
              f'{os.path.basename(output_txt)} -- build with `merlin32 -v1`')
        sys.exit(1)

    low = _read_symbol(output_txt, 'KSEG_LOW')
    end = _read_symbol(output_txt, 'KSEG_END')
    if low is None and end is None:
        return False  # no segment in this image -- the assemble-time
                       # no-op case, nothing to do
    if low is None or end is None:
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: '
              f'KSEG_LOW={low} KSEG_END={end} -- one label exists '
              f'without the other, which the manifest should never '
              f'produce (both are written together)')
        sys.exit(1)

    org = cki.get_manifest_org(manifest_path)
    if org is None:
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: no `org` '
              f'found in {manifest_path}')
        sys.exit(1)

    # KSEG_LOW is in the FLAT ($2000-ish) address space -- the point in
    # the manifest right before `org KSEG_ORG` switches to the segment's
    # OWN ($D400) address space, where KSEG_END is resolved. The two are
    # NOT in the same address space, so the segment's length is
    # KSEG_END - KSEG_ORG (both $D400-based), never KSEG_END - KSEG_LOW.
    kseg_org = _read_symbol(output_txt, 'KSEG_ORG')
    if kseg_org is None:
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: no '
              f'KSEG_ORG symbol in {output_txt} (inc/mm.hw.equ)')
        sys.exit(1)

    seg_len = end - kseg_org
    if seg_len <= 0 or seg_len > KSEG_MAXPG * 256:
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: segment '
              f'is {seg_len} B (KSEG_ORG=${kseg_org:04X} '
              f'KSEG_END=${end:04X}) '
              f'-- must be > 0 and <= {KSEG_MAXPG * 256} B ($D400-$DFFF); '
              f'a segment that crosses $E000 is a build failure, not a '
              f'warning (docs/KSEG.md)')
        sys.exit(1)

    with open(sys_path, 'rb') as fh:
        raw = fh.read()

    # `.full`: the RAW, UNSPLIT, UNPADDED output -- flat part and
    # segment CONTIGUOUS, exactly as merlin32 emitted it, before this
    # function cuts and pads. check_nas_librel.py's own comparison
    # needs THIS, not the split .SYSTEM: nas+ld links a segment-
    # bearing manifest's flat part and cold segment as one contiguous
    # $2000-based image too (an `-s KSEG_ORG` override, not a separate
    # file the way merlin32's own build gets split afterward), so the
    # byte-identity reference for THAT comparison is this file, not
    # the post-split `.SYSTEM` the boot-time harnesses load.
    with open(sys_path + '.full', 'wb') as fh:
        fh.write(raw)

    cut = low - org
    if cut < 0 or cut > len(raw):
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: computed '
              f'flat-part length {cut} is outside the built file '
              f'({len(raw)} B) -- org=${org:04X} KSEG_LOW=${low:04X}')
        sys.exit(1)
    # -- the play-only LOW segment (docs/LOOP-S1.md): LSEG_ORG..LSEG_END,
    # -- laid down right after the KSEG bytes. Absent = a manifest with
    # -- no low segment (every image but the play image).
    lseg_org = _read_symbol(output_txt, 'LSEG_ORG')
    lseg_end = _read_symbol(output_txt, 'LSEG_END')
    lseg_len = 0
    if lseg_org is not None and lseg_end is not None:
        lseg_len = lseg_end - lseg_org
        if lseg_len <= 0 or lseg_len > LSEG_MAXPG * 256:
            print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: low '
                  f'segment is {lseg_len} B (LSEG_ORG=${lseg_org:04X} '
                  f'LSEG_END=${lseg_end:04X}) -- must be > 0 and <= '
                  f'{LSEG_MAXPG * 256} B ($1300-$1AFF)')
            sys.exit(1)
    if len(raw) != cut + seg_len + lseg_len:
        print(f'[split-kseg] FAIL {os.path.basename(sys_path)}: built '
              f'file is {len(raw)} B, expected flat {cut} + segment '
              f'{seg_len} + low segment {lseg_len} = '
              f'{cut + seg_len + lseg_len} -- something followed the '
              f'segments in the manifest (docs/KSEG.md: the segments '
              f'must be the LAST things put)')
        sys.exit(1)

    flat_bytes = raw[:cut]
    seg_bytes = raw[cut:cut + seg_len]
    lseg_bytes = raw[cut + seg_len:]

    # PAD to a 256-byte boundary (docs/KSEG.md "The loader", coordinator
    # review 2026-09-27 "ONE loader"): KSEG_LOAD's read loop assumes every
    # KSEG-family file is a whole number of 256-byte pages, exactly like
    # byeres.bin's own long-standing padded convention -- a real 1916 B
    # segment (7 full pages + a 124-byte tail) fed to that loop UNPADDED
    # made the final short-but-nonzero read look like a genuine I/O
    # error (trans_count=124, neither 0 nor 256) instead of the clean
    # EOF it actually is. MEASURED as a real boot hang (K_HALT_MARK=$7C,
    # 124 decimal -- the tail length itself, read back as the "error"),
    # 2026-09-27, before this padding was added.
    pad = (-len(seg_bytes)) % 256
    if pad:
        seg_bytes = seg_bytes + b'\x00' * pad

    with open(sys_path, 'wb') as fh:
        fh.write(flat_bytes)

    kseg_path = sys_path[:-len('.SYSTEM')] + '_KSEG' \
        if sys_path.endswith('.SYSTEM') else sys_path + '_KSEG'
    with open(kseg_path, 'wb') as fh:
        fh.write(seg_bytes)

    if lseg_len:
        lpad = (-len(lseg_bytes)) % 256
        lseg_bytes = lseg_bytes + b'\x00' * lpad
        lseg_path = sys_path[:-len('.SYSTEM')] + '_LSEG' \
            if sys_path.endswith('.SYSTEM') else sys_path + '_LSEG'
        with open(lseg_path, 'wb') as fh:
            fh.write(lseg_bytes)
        print(f'[split-kseg] {os.path.basename(lseg_path)}: low segment '
              f'{lseg_len} B (+{lpad} B pad) = {len(lseg_bytes)} B')
    print(f'[split-kseg] {os.path.basename(sys_path)}: cut at ${low:04X} '
          f'(file offset {cut}) -- flat {len(flat_bytes)} B, segment '
          f'{len(seg_bytes)} B (padded +{pad} B to a 256-byte boundary) '
          f'-> {os.path.basename(kseg_path)}')
    return True


def main(argv):
    graph, _put_targets = cm.build_graph()
    images, _process_bearing = cki.derive_kernel_images(graph)
    # images: {manifest_path: {set of .SYSTEM target paths}}
    pairs = []
    for manifest_path, targets in images.items():
        for t in targets:
            pairs.append((t, manifest_path))

    if argv:
        want = {argv[0], argv[0] + '.SYSTEM'} if not argv[0].endswith(
            '.SYSTEM') else {argv[0]}
        pairs = [(t, m) for t, m in pairs
                 if os.path.basename(t) in want]
        if not pairs:
            print(f'[split-kseg] no kernel image matches {argv[0]!r}')
            return 1

    any_seg = False
    for sys_path, manifest_path in sorted(pairs):
        if split_one(sys_path, manifest_path):
            any_seg = True
    if not any_seg:
        print('[split-kseg] no image in this run carries a KSEG segment '
              '(expected unless the segment-bearing manifest was just '
              'rebuilt)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
