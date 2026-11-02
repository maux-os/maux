#!/usr/bin/env python3
"""Pack a raw SmartPort block image: block 0 = the assembled boot block,
everything else zero-filled. No filesystem -- this is disk-image strategy
stage 0 from docs/TASKS.md #1 ("raw SmartPort block image, bootblock.s
dd'd into block 0 (crib malisp), no fs").

Deterministic: output depends only on the boot block's bytes and the
requested block count -- no timestamps, no host-specific metadata, so
`make` reproduces the exact same image bytes every time.

Usage: build_image.py <bootblock.bin> <out.po> <total_blocks>
"""
import sys

BLOCK_SIZE = 512


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    bootblock_path, out_path, total_blocks_s = sys.argv[1:4]
    total_blocks = int(total_blocks_s)

    with open(bootblock_path, "rb") as f:
        bootblock = f.read()
    if len(bootblock) != BLOCK_SIZE:
        print(f"error: {bootblock_path} is {len(bootblock)} bytes, "
              f"expected exactly {BLOCK_SIZE} (one disk block)", file=sys.stderr)
        return 1

    image = bytearray(BLOCK_SIZE * total_blocks)
    image[0:BLOCK_SIZE] = bootblock

    with open(out_path, "wb") as f:
        f.write(image)

    print(f"wrote {out_path}: {len(image)} bytes ({total_blocks} blocks), "
          f"block 0 = {bootblock_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
