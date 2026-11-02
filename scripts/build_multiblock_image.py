#!/usr/bin/env python3
"""Pack a raw SmartPort block image whose payload spans MORE than one
block: block 0 = the payload's own first 512 bytes (a tiny chain-loader,
src/test/syscalltest.s's LOADER section), blocks 1..N-1 = the rest of
the SAME assembled binary, laid out sequentially -- everything else
zero-filled. No filesystem, same "deterministic, no timestamps" contract
as scripts/build_image.py, extended to a payload that isn't exactly one
block (task #3's syscalltest.s needs more than 512 bytes for the kernel
skeleton + $FFxx template + fake-process program + mouse/print code, so
its own block-0 loader reads the rest of itself via SmartPort READ_BLOCK
-- see that file's LOADER section header for why).

Usage: build_multiblock_image.py <payload.bin> <out.po> <total_blocks>
"""
import sys

BLOCK_SIZE = 512


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    payload_path, out_path, total_blocks_s = sys.argv[1:4]
    total_blocks = int(total_blocks_s)

    with open(payload_path, "rb") as f:
        payload = f.read()
    if len(payload) % BLOCK_SIZE != 0:
        print(f"error: {payload_path} is {len(payload)} bytes, not a "
              f"multiple of {BLOCK_SIZE} -- the source file's own trailing "
              f"`ds` pad should guarantee this", file=sys.stderr)
        return 1
    payload_blocks = len(payload) // BLOCK_SIZE
    if payload_blocks > total_blocks:
        print(f"error: {payload_path} needs {payload_blocks} blocks, "
              f"more than the requested {total_blocks}-block image",
              file=sys.stderr)
        return 1

    image = bytearray(BLOCK_SIZE * total_blocks)
    image[0:len(payload)] = payload

    with open(out_path, "wb") as f:
        f.write(image)

    print(f"wrote {out_path}: {len(image)} bytes ({total_blocks} blocks), "
          f"blocks 0-{payload_blocks - 1} = {payload_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
