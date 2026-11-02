#!/usr/bin/env python3
"""stage_putbin.py -- turn a `putbin <blob>` line into real-Merlin-legal
`PUT`-file HEX source (docs/AS-DESIGN.md's ld.s/as.s staging step).

WHY THIS EXISTS. `src/bin/mld.s` and `src/bin/as.s` embed three binary
blobs (the process core and P6 stub) with merlin32's `putbin` directive.
Real Merlin-8 2.59 HAS NO `putbin` -- checked 2026-08-23 against the
vendored public-domain source: `vendor/merlin/OPCODES.S`'s `PSEUDO` table
(the literal dispatch table `GETOPC`, `vendor/merlin/ASS.BNK1.S:288-307`,
linear-scans) does not contain it. So staging a unit for real Merlin must
rewrite each `putbin <blob>` line into source real Merlin CAN assemble:
a `HEX` dump, `PUT` in from a separate file.

Two dialect ceilings shape the split (both learnings cited below):

  * a Merlin-8 source LINE is capped at 64 characters
    (learning:01M04SAJTJAYXCR3YNFW313FMZ) -- 16 bytes/line as
    " HEX " + 32 hex digits is 37 characters, comfortably inside it;

  * the 41,215-byte ($0901-$AA00) source buffer
    (learning:01M051EM2HQ3ZVJTR1W9P3G86J), and its 2026-08-23
    CORRECTION on learning:01M0CC62FZ351EBXCAAKX52KAJ: **PUT
    RECLAIMS** -- each PUT file loads at ENDSRC+1 and the NEXT put
    reuses that same region, so only USE is permanently resident. The
    per-unit budget is `resident top-level + Sum(USE files) + LARGEST
    single PUT file <= 41215`. Splitting one big blob into several
    smaller PUT files lowers that LARGEST term, which is the entire
    point of this module: `cap` bounds each file's SOURCE TEXT size
    (not the blob's byte count), and the split additionally tries to
    BALANCE the files (not merely fill each one up to `cap`) so the
    largest single file -- the number that actually counts against the
    budget -- is as small as the file count allows.

INTERFACE

    blob_to_hex_puts(blob_path, flat_prefix, cap=6000, per_line=16)
        -> list[(flat_name, source_text)]

    putbin_replacement_lines(flat_names, dir_prefix='/mnt/MAUXSRC/SRC/')
        -> list[str]

Both are pure functions: no I/O beyond reading `blob_path`. The caller
(a future build script, NOT this module -- see the task brief) is
responsible for writing `source_text` to `<flat_name>.S` on the staged
volume and for splicing `putbin_replacement_lines` in place of the
original `putbin` line. `dir_prefix` defaults to
`/mnt/MAUXSRC/SRC/` -- the dependency subdirectory
build_maux_src_image.py's "WHY A SUBDIRECTORY FOR DEPENDENCIES" note
stages every non-top-level file into (the ProDOS VOLUME directory is a
hard 4-block, ~51-slot structure that overflowed outright at file 53;
a SUBdirectory has no such ceiling). `build_maux_src_image.py` imports
`MAX_FLAT_NAME` from here as the single owner of that constant.
"""
import os
import re
import sys

# Merlin's PUT appends ".S" itself and reads a ProDOS flat file name:
# uppercase letters, digits, '.', starting with a letter. ProDOS's own
# filename ceiling is 15 characters, but that ceiling applies to the
# name Merlin is actually handed -- flat_name + the ".S" PUT appends --
# not to flat_name alone. So the real limit on flat_name is 15 - len(".S")
# = 13.
FLAT_NAME_RE = re.compile(r'^[A-Za-z][A-Za-z0-9.]*$')
MAX_FLAT_NAME = 13

# " HEX " (opcode column, no label) + hex digits. This fixed prefix is
# what bounds how large `per_line` may get before a line would break
# the 64-character limit (learning:01M04SAJTJAYXCR3YNFW313FMZ).
HEX_PREFIX = " HEX "


def _hex_line(chunk):
    """One ` HEX ...` source line for a <=per_line-byte chunk."""
    return HEX_PREFIX + chunk.hex().upper()


def hex_source_to_bytes(source_text):
    """Parse HEX lines back to bytes -- the inverse of the lines this
    module emits. Blank lines are ignored (a file's text may or may not
    carry a trailing newline); anything else must be an ` HEX ...` line
    with an even number of hex digits."""
    out = bytearray()
    for raw in source_text.splitlines():
        line = raw.strip()
        if not line:
            continue
        upper = line.upper()
        if not upper.startswith('HEX '):
            raise ValueError(f'not a HEX line: {raw!r}')
        digits = line[4:].strip()
        if len(digits) % 2 != 0:
            raise ValueError(f'odd number of hex digits: {raw!r}')
        out += bytes.fromhex(digits)
    return bytes(out)


def _greedy_fill_count(sizes, capacity):
    """Fewest contiguous groups of `sizes` (in order) such that each
    group's sum is <= capacity. Greedy (fill each group as full as
    possible before starting the next) is optimal for MINIMIZING THE
    GROUP COUNT under a fixed capacity -- a standard bin-covering fact
    for contiguous partitions. Raises if a single element alone
    exceeds capacity (no split can ever satisfy that)."""
    count = 1
    cur = 0
    for size in sizes:
        if size > capacity:
            raise ValueError(
                f'a single line ({size} bytes) exceeds capacity '
                f'({capacity} bytes) -- lower per_line or raise cap')
        if cur + size > capacity:
            count += 1
            cur = 0
        cur += size
    return count


def _greedy_fill_groups(items, sizes, capacity):
    """Same greedy pass as `_greedy_fill_count`, but returns the actual
    groups of `items` (parallel to `sizes`), preserving order."""
    groups = []
    cur_items = []
    cur = 0
    for item, size in zip(items, sizes):
        if cur_items and cur + size > capacity:
            groups.append(cur_items)
            cur_items = []
            cur = 0
        cur_items.append(item)
        cur += size
    if cur_items:
        groups.append(cur_items)
    return groups


def _balanced_groups(items, sizes, cap):
    """Split `items` (with parallel byte `sizes`) into contiguous groups
    so that (a) every group's size <= cap and (b) subject to (a), using
    the FEWEST files possible, and (c) subject to (a) and (b), the
    LARGEST group is as small as it can be made.

    `cap` is a hard ceiling, not a fill target -- naive greedy-fill packs
    the first file right up against `cap` and starves the rest, which
    maximizes exactly the number (the largest single PUT file) that
    counts against the 41,215-byte budget. This is the classic "split
    array into K parts, minimize the largest part sum" problem: find the
    minimum groups-under-`cap` count k_min (greedy is optimal for that),
    then binary-search the smallest capacity M >= k_min-feasible at
    which the same greedy pass still uses <= k_min groups. Greedy at
    that M is then both order-preserving and balanced.
    """
    total = sum(sizes)
    if not items:
        return [[]]
    if total <= cap:
        return [list(items)]

    k_min = _greedy_fill_count(sizes, cap)

    lo, hi = max(sizes), cap
    while lo < hi:
        mid = (lo + hi) // 2
        if _greedy_fill_count(sizes, mid) <= k_min:
            hi = mid
        else:
            lo = mid + 1
    return _greedy_fill_groups(items, sizes, lo)


def _flat_names(prefix, count):
    """`count` unique, ProDOS-legal, <=MAX_FLAT_NAME-char flat names,
    `prefix` followed by a zero-padded 1-based sequence number wide
    enough for `count` files."""
    if count <= 0:
        return []
    width = len(str(count))
    names = []
    for i in range(1, count + 1):
        name = f'{prefix}{i:0{width}d}'
        if len(name) > MAX_FLAT_NAME:
            raise ValueError(
                f'flat name {name!r} is {len(name)} chars, max '
                f'{MAX_FLAT_NAME} -- shorten flat_prefix')
        if not FLAT_NAME_RE.match(name):
            raise ValueError(f'flat name {name!r} is not ProDOS-legal')
        names.append(name)
    if len(set(names)) != len(names):
        raise ValueError(f'flat names not unique: {names}')
    return names


def blob_to_hex_puts(blob_path, flat_prefix, cap=6000, per_line=16):
    """Read `blob_path` and return `[(flat_name, source_text), ...]` --
    Merlin `HEX` source, `per_line` bytes/line, split across as many
    files as needed so no single file's SOURCE TEXT exceeds `cap` bytes
    (balanced within that, see `_balanced_groups`). `flat_name` is the
    PUT-able name WITHOUT the `.S` suffix Merlin appends itself.

    Asserts its own round-trip, line-length, and syntax properties
    before returning -- a caller never sees output this module has not
    already verified against the source blob.
    """
    if per_line < 1:
        raise ValueError('per_line must be >= 1')
    max_line_len = len(HEX_PREFIX) + 2 * per_line
    if max_line_len > 64:
        raise ValueError(
            f'per_line={per_line} makes a {max_line_len}-char line -- '
            f'exceeds Merlin-8\'s 64-character source-line limit '
            f'(learning:01M04SAJTJAYXCR3YNFW313FMZ)')

    with open(blob_path, 'rb') as f:
        blob = f.read()

    lines = [_hex_line(blob[i:i + per_line])
              for i in range(0, len(blob), per_line)]
    # Every emitted line's own trailing newline counts toward the file's
    # source-text size -- including the last line of a file, since the
    # host writes text files with a trailing newline throughout this
    # tree. Measured this way, HEX_PREFIX+16 bytes/line (blob 4045B)
    # reproduces exactly 9608 bytes of source text, matching the task's
    # measured table.
    sizes = [len(line) + 1 for line in lines]

    groups = _balanced_groups(lines, sizes, cap)
    names = _flat_names(flat_prefix, len(groups))

    results = []
    for name, group in zip(names, groups):
        text = ''.join(line + '\n' for line in group)
        results.append((name, text))

    _assert_properties(results, cap)
    roundtrip = b''.join(hex_source_to_bytes(text) for _, text in results)
    if roundtrip != blob:
        raise AssertionError(
            f'round-trip mismatch for {blob_path}: {len(blob)} bytes in, '
            f'{len(roundtrip)} bytes out')

    return results


def _assert_properties(results, cap):
    """Line-length, opcode/operand syntax, and cap properties -- run on
    every call, not just under the test gate."""
    names_seen = set()
    for name, text in results:
        if len(name) > MAX_FLAT_NAME or not FLAT_NAME_RE.match(name):
            raise AssertionError(f'bad flat name: {name!r}')
        if name in names_seen:
            raise AssertionError(f'duplicate flat name: {name!r}')
        names_seen.add(name)

        encoded_len = len(text.encode('ascii'))
        if encoded_len > cap:
            raise AssertionError(
                f'{name}: {encoded_len} bytes exceeds cap {cap}')

        for line in text.splitlines():
            if len(line) > 64:
                raise AssertionError(
                    f'{name}: line exceeds 64 chars: {line!r}')
            if not line:
                continue
            stripped = line.strip()
            opcode, _, operand = stripped.partition(' ')
            if opcode.upper() != 'HEX':
                raise AssertionError(f'{name}: opcode is not HEX: {line!r}')
            operand = operand.strip()
            if len(operand) % 2 != 0:
                raise AssertionError(
                    f'{name}: odd hex-digit operand: {line!r}')
            if operand and not all(c in '0123456789ABCDEF' for c in operand):
                raise AssertionError(
                    f'{name}: non-hex operand digits: {line!r}')


def putbin_replacement_lines(flat_names, dir_prefix='/mnt/MAUXSRC/SRC/'):
    """The `PUT`-directive lines that replace one `putbin` line, in
    order. Merlin's PUT appends `.S` itself, so `flat_names` are given
    WITHOUT the suffix. `dir_prefix` defaults to the dependency
    subdirectory every staged HEX-PUT file actually lives in
    (build_maux_src_image.py's SRCDIR, "WHY A SUBDIRECTORY FOR
    DEPENDENCIES") -- callers staging into a different location pass
    their own prefix; the interface makes no assumption about it beyond
    string concatenation."""
    return [f' PUT {dir_prefix}{name}' for name in flat_names]


if __name__ == '__main__':
    # Manual smoke check against the real blobs this task exists for --
    # scripts/check_stagebin.py is the actual gate.
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    blobs = [
        (os.path.join(root, 'build', 'ascore-process-bank1.obj'), 'ASPB1'),
        (os.path.join(root, 'build', 'ascore-process-as.obj'), 'ASPAS'),
        (os.path.join(root, 'build', 'as-stubs.bin'), 'ASSTB'),
    ]
    total_files = 0
    largest = 0
    for path, prefix in blobs:
        if not os.path.exists(path):
            print(f'(missing, skipped) {path}', file=sys.stderr)
            continue
        results = blob_to_hex_puts(path, prefix)
        sizes = [len(text.encode('ascii')) for _, text in results]
        total_files += len(results)
        largest = max(largest, max(sizes))
        print(f'{os.path.basename(path)}: {len(results)} file(s), '
              f'sizes={sizes}')
    print(f'total files={total_files} largest={largest}')
