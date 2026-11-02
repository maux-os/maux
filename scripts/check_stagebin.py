#!/usr/bin/env python3
"""check_stagebin.py -- host-only gate for stage_putbin.py (`make check-stagebin`).

WHY THIS EXISTS. Real Merlin-8 2.59 has no `putbin` directive (checked
against the vendored public-domain source; see stage_putbin.py's module
docstring). `src/bin/mld.s` and `src/bin/as.s` each embed binary blobs
with `putbin`, so staging a unit for real Merlin has to rewrite those
lines into `HEX`-dump `PUT` files stage_putbin.py produces. This gate
proves that module's output against the REAL blobs on disk (not only
synthetic fixtures), and against a battery of hand-picked edge cases.

WHAT THIS GATE DOES NOT PROVE. Every byte-preservation check here is a
Python -> Python round-trip: `blob_to_hex_puts()` writes HEX text and
`hex_source_to_bytes()` (also pure Python) parses it back. NO ASSEMBLER
HAS EVER CONSUMED THESE HEX FILES -- not merlin32, not real Merlin-8.
That the emitted text is syntactically HEX-legal (opcode, even hex
digits, <=64-char lines) is checked independently below, but whether
real Merlin actually assembles it into the same bytes is unverified
until `check_dual.py` (or an equivalent) stages one of these files and
runs it through the real assembler. Do not read the PASS line below as
more than what it says.

No emulator involved otherwise -- pure Python, like
check_bytes.py/check_equ_fwd.py.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
import stage_putbin  # noqa: E402
import strip_comments as sc  # noqa: E402
import check_manifests as cm  # noqa: E402 -- put/use/putbin graph machinery

BUILD = os.path.join(ROOT, 'build')

# real Merlin's source buffer: $0901..$AA00 (learning:01M051EM2HQ3ZVJTR1W9P3G86J),
# and its 2026-08-23 correction on learning:01M0CC62FZ351EBXCAAKX52KAJ ("PUT
# reclaims"): PUT files never accumulate, only USE files do, so the budget
# per unit is manifest + all `use` files + its LARGEST single `put` file.
BUFFER_CEILING = 41215

# The dependency subdirectory build_maux_src_image.py actually stages
# HEX-PUT files into (its SRCDIR = 'SRC', "WHY A SUBDIRECTORY FOR
# DEPENDENCIES" -- the ProDOS VOLUME directory is a hard 4-block, ~51-slot
# structure that overflowed outright at file 53; a SUBdirectory has no
# such ceiling). Passed explicitly to stage_putbin.putbin_replacement_lines
# below so this gate exercises the PARAMETERIZED form, not a value the
# module happens to default to.
DIR_PREFIX = '/mnt/MAUXSRC/SRC/'

CAP = 6000
PER_LINE = 16

failures = []


def check(label, cond, detail=''):
    status = 'ok' if cond else 'FAIL'
    print(f'[check-stagebin] {status}: {label}'
          + (f' -- {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(label)
    return cond


def _blob_prefix(abspath):
    """Deterministic ProDOS-legal flat-name prefix for a putbin blob,
    derived from its own basename -- no hand-maintained name table to
    fall out of sync (HACKING.md's "Knowing a house tool exists" entry:
    a hand-list of files went stale three times in one day in this
    tree). Initials of every stem word but the last, plus the last word
    in full: the trailing token is what actually distinguishes
    'ascore-process-bank1' from 'ascore-process-as', so it survives
    intact while the shared 'ascore-process' collapses to 'AP'."""
    stem = os.path.splitext(os.path.basename(abspath))[0]
    words = [w for w in re.split(r'[^A-Za-z0-9]+', stem) if w]
    if not words:
        return 'BLOB'
    initials = ''.join(w[0] for w in words[:-1]).upper()
    last = re.sub(r'[^A-Za-z0-9]', '', words[-1]).upper()
    return initials + last


def derive_putbin_blobs(graph):
    """[(rel_path, prefix), ...] for every DISTINCT putbin target in the
    whole tree -- replaces a hand-maintained REAL_BLOBS list.
    check_manifests.build_graph() emits `('putbin', resolved_target,
    lineno)` edges as a first-class edge kind (BLOB_DIRECTIVES); whatever
    putbin edges the tree currently carries is what gets checked here,
    so a blob added, removed, or renamed in ld.s/as.s is picked up with
    no list to edit and nothing to go stale."""
    targets = []
    seen = set()
    for path in sorted(graph):
        for directive, tgt, _lineno in graph[path]:
            if directive != 'putbin' or tgt in seen:
                continue
            seen.add(tgt)
            targets.append(tgt)
    blobs = [(cm.rel(t), _blob_prefix(t)) for t in sorted(targets)]
    prefixes = [p for _, p in blobs]
    assert len(set(prefixes)) == len(prefixes), (
        f'derived blob prefixes collide -- extend _blob_prefix: {blobs}')
    return blobs


def derive_putbin_units(graph, tops):
    """Top-level manifests (check_manifests.toplevel_manifests()) that
    embed at least one putbin blob -- currently src/bin/mld.s and
    src/bin/as.s, but derived rather than named so a third unit gaining
    a putbin line is picked up automatically."""
    return sorted(t for t in tops
                  if any(d == 'putbin' for d, _, _ in graph.get(t, ())))


def check_real_blobs(graph, blobs):
    """Round-trip + syntax + PUT-line-shape, against the actual build/
    blobs ld.s/as.s embed (derived via derive_putbin_blobs, see above)."""
    any_missing = False
    for rel_path, prefix in blobs:
        path = os.path.join(ROOT, rel_path)
        if not os.path.exists(path):
            check(f'{rel_path} exists', False,
                  'run `make check-userland` (or '
                  '`python3 scripts/build_ascore_image.py --variant '
                  'process`) to build it first')
            any_missing = True
            continue

        with open(path, 'rb') as f:
            blob = f.read()

        results = stage_putbin.blob_to_hex_puts(path, prefix, cap=CAP,
                                                   per_line=PER_LINE)

        # 1. round-trip byte-exactness, re-derived here (not merely
        # trusting the module's own internal assert). Python -> Python
        # only -- see the module docstring's honesty note.
        roundtrip = b''.join(stage_putbin.hex_source_to_bytes(text)
                              for _, text in results)
        check(f'{rel_path}: round-trip byte-exact ({len(blob)} bytes)',
              roundtrip == blob,
              f'got {len(roundtrip)} bytes back')

        # 2. line-length / syntax properties, re-checked independently
        # and STRICTLY: opcode is exactly HEX, the operand is nothing
        # but hex digits (this specifically catches a space anywhere in
        # the operand, which merlin-8 dialect treats as terminating the
        # expression right there -- learning:01M051DJW89KV4JYM1EC9SDZ5Y),
        # and its length is even.
        all_lines_ok = True
        for name, text in results:
            for line in text.splitlines():
                if len(line) > 64:
                    all_lines_ok = False
                    continue
                stripped = line.strip()
                opcode, sep, operand = stripped.partition(' ')
                if (opcode.upper() != 'HEX' or sep != ' '
                        or re.fullmatch(r'[0-9A-F]*', operand) is None
                        or len(operand) % 2 != 0):
                    all_lines_ok = False
        check(f'{rel_path}: every line <=64 chars, opcode HEX, operand '
              f'all-hex-digit and even-length (no embedded space)',
              all_lines_ok)

        # flat names: unique, legal, <=MAX_FLAT_NAME chars, and PUT
        # lines derived from them round-trip to the parameterized form
        # -- NOT a hardcoded literal (review finding N2: a later commit
        # on this branch moved every staged dependency to
        # /mnt/MAUXSRC/SRC/, so asserting the old /mnt/MAUXSRC/ literal would
        # pass this gate while failing the real staged image).
        names = [n for n, _ in results]
        put_lines = stage_putbin.putbin_replacement_lines(
            names, dir_prefix=DIR_PREFIX)
        check(f'{rel_path}: {len(names)} unique <='
              f'{stage_putbin.MAX_FLAT_NAME}-char flat name(s)',
              len(set(names)) == len(names)
              and all(len(n) <= stage_putbin.MAX_FLAT_NAME for n in names)
              and all(stage_putbin.FLAT_NAME_RE.match(n) for n in names),
              str(names))
        check(f'{rel_path}: PUT replacement lines name each file under '
              f'{DIR_PREFIX}',
              put_lines == [f' PUT {DIR_PREFIX}{n}' for n in names],
              str(put_lines))

        sizes = [len(text.encode('ascii')) for _, text in results]
        print(f'[check-stagebin]   {rel_path}: {len(results)} file(s), '
              f'sizes={sizes}')

    return any_missing


def real_unit_budget(graph, top):
    """(resident, largest, largest_src, total) for one top-level unit
    AFTER its putbin lines are staged as HEX/PUT files -- the REAL
    per-unit inequality real Merlin enforces: stripped manifest +
    stripped `use` files + the largest single `put` file (an existing
    regular put, OR one of the HEX files stage_putbin.py splits a
    putbin blob into, whichever is larger) <= BUFFER_CEILING. Stripped
    sizes (via strip_comments.strip_file, the single owner of the
    stripping rule) because stripped text -- not the master tree's raw
    file -- is what real Merlin is actually handed once
    build_maux_src_image.py stages the tree."""
    edges = graph[top]
    manifest = len(sc.strip_file(top))
    use_sz = sum(len(sc.strip_file(t)) for d, t, _ in edges
                 if d == 'use' and os.path.exists(t))
    resident = manifest + use_sz

    largest, largest_src = 0, '-'
    for d, t, _ in edges:
        if d == 'put' and os.path.exists(t):
            s = len(sc.strip_file(t))
            if s > largest:
                largest, largest_src = s, cm.rel(t)
        elif d == 'putbin' and os.path.exists(t):
            prefix = _blob_prefix(t)
            hex_results = stage_putbin.blob_to_hex_puts(
                t, prefix, cap=CAP, per_line=PER_LINE)
            for name, text in hex_results:
                s = len(text.encode('ascii'))
                if s > largest:
                    largest, largest_src = s, f'{cm.rel(t)} -> {name}.S'

    return resident, largest, largest_src, resident + largest


def check_real_budget(graph, tops):
    """The REAL per-unit budget inequality (manifest + use + largest
    put, all as they will exist AFTER putbin staging) for every
    putbin-bearing top-level unit -- not merely the largest raw blob,
    which is what an earlier version of this gate checked (review
    finding N7.2)."""
    print()
    print(f'[check-stagebin] real per-unit budget after putbin staging '
          f'(stripped manifest + stripped use + largest single put '
          f'<= {BUFFER_CEILING})')
    units = derive_putbin_units(graph, tops)
    check('at least one top-level unit embeds a putbin blob',
          len(units) > 0,
          'derive_putbin_units() found none -- expected src/bin/mld.s '
          'and src/bin/as.s')
    for top in units:
        resident, largest, largest_src, total = real_unit_budget(graph, top)
        headroom = BUFFER_CEILING - total
        print(f'[check-stagebin]   {cm.rel(top)}: resident={resident} '
              f'largest={largest} ({largest_src}) total={total} vs '
              f'ceiling {BUFFER_CEILING} -> headroom {headroom}')
        check(f'{cm.rel(top)}: real budget fits under {BUFFER_CEILING}',
              total <= BUFFER_CEILING, f'{total} > {BUFFER_CEILING}')
        check(f'{cm.rel(top)}: positive headroom remains',
              headroom > 0, f'headroom={headroom}')


def _synthetic_blob(tmp_path, data):
    with open(tmp_path, 'wb') as f:
        f.write(data)


def check_edge_cases():
    """Synthetic battery: empty blob, 1 byte, exactly per_line bytes,
    per_line+1 bytes, exactly cap-sized, and just over cap."""
    import tempfile
    cases = {
        'empty (0 bytes)': b'',
        '1 byte': b'\xAB',
        f'exactly per_line ({PER_LINE}) bytes': bytes(range(PER_LINE)),
        f'per_line+1 ({PER_LINE + 1}) bytes': bytes(range(PER_LINE + 1)),
    }
    # A blob whose HEX source is exactly `cap` bytes, and one whose HEX
    # source is one byte over. Each 16-byte chunk emits a 38-byte line
    # (37 chars + \n) except a possible short final line; picking a
    # cap that is an exact multiple of 38 keeps this exact and simple.
    line_bytes = len(stage_putbin.HEX_PREFIX) + 2 * PER_LINE + 1  # 38
    exact_cap = (CAP // line_bytes) * line_bytes
    n_full_lines_at_cap = exact_cap // line_bytes
    cases[f'source exactly at cap ({exact_cap} bytes)'] = \
        bytes((i % 251) for i in range(n_full_lines_at_cap * PER_LINE))
    cases[f'source one line over cap'] = \
        bytes((i % 251) for i in range((n_full_lines_at_cap + 1) * PER_LINE))

    with tempfile.TemporaryDirectory() as tmp:
        for label, data in cases.items():
            path = os.path.join(tmp, 'blob.bin')
            _synthetic_blob(path, data)
            try:
                results = stage_putbin.blob_to_hex_puts(
                    path, 'EDGE', cap=exact_cap, per_line=PER_LINE)
            except Exception as exc:  # noqa: BLE001 -- report, don't crash
                check(f'edge case [{label}]: blob_to_hex_puts succeeds',
                      False, f'raised {exc!r}')
                continue

            roundtrip = b''.join(stage_putbin.hex_source_to_bytes(text)
                                  for _, text in results)
            check(f'edge case [{label}]: round-trip byte-exact '
                  f'({len(data)} bytes)', roundtrip == data,
                  f'got {len(roundtrip)} bytes back')

            sizes = [len(text.encode('ascii')) for _, text in results]
            check(f'edge case [{label}]: every file <= cap ({exact_cap})',
                  all(s <= exact_cap for s in sizes), str(sizes))

            names = [n for n, _ in results]
            check(f'edge case [{label}]: unique legal flat names',
                  len(set(names)) == len(names)
                  and all(len(n) <= stage_putbin.MAX_FLAT_NAME
                          for n in names)
                  and all(stage_putbin.FLAT_NAME_RE.match(n) for n in names),
                  str(names))

            for name, text in results:
                for line in text.splitlines():
                    if len(line) > 64:
                        check(f'edge case [{label}]: line <=64 chars',
                              False, repr(line))
                        break
                else:
                    continue
                break
            else:
                check(f'edge case [{label}]: every line <=64 chars', True)


def check_overlong_name_guard():
    """Two checks on the flat-name-length guard, deliberately NOT the
    same check twice:

    1. An INDEPENDENT re-check that does not trust
       stage_putbin.MAX_FLAT_NAME's current value at all: ProDOS's own
       15-char filename ceiling applies to what real Merlin's PUT
       actually reads -- flat_name + the ".S" suffix PUT appends
       itself -- so no flat_name may legally exceed 15 - len(".S") ==
       13 characters, full stop, independent of whatever the module
       claims. This is the check that actually has teeth against N3's
       bug: if MAX_FLAT_NAME were wrongly reverted to 15, a 14-char
       name would NOT trip the module's OWN guard (14 is not > 15) --
       silent pass on a name real Merlin cannot legally PUT -- but it
       still trips this one, because 13 is hardcoded here, not read
       from the module under test.

    2. The module's own guard, exercised at whatever MAX_FLAT_NAME
       currently is, so a plain regression (the guard stops raising at
       all, independent of what the constant's value is) is still
       caught even when the constant itself is correct.
    """
    REAL_MAX_FLAT_NAME = 13  # ProDOS's 15 minus len(".S") -- hardcoded
                              # here on purpose, never read from
                              # stage_putbin.MAX_FLAT_NAME.
    prefix = 'X' * REAL_MAX_FLAT_NAME               # 13 chars
    name14 = prefix + '1'                           # 14 chars if it survives
    try:
        stage_putbin._flat_names(prefix, 1)
        check(f'flat name {name14!r} (14 chars, > the ProDOS-real '
              f'{REAL_MAX_FLAT_NAME}-char limit) is rejected -- checked '
              f'independent of stage_putbin.MAX_FLAT_NAME\'s current '
              f'value', False,
              f'{name14!r} should have raised ValueError but did not')
    except ValueError:
        check(f'flat name {name14!r} (14 chars, > the ProDOS-real '
              f'{REAL_MAX_FLAT_NAME}-char limit) is rejected -- checked '
              f'independent of stage_putbin.MAX_FLAT_NAME\'s current '
              f'value', True)

    overlong_prefix = 'X' * (stage_putbin.MAX_FLAT_NAME + 1)
    try:
        stage_putbin._flat_names(overlong_prefix, 1)
        check("over-length flat name is rejected (module's own guard, "
              "at its own current MAX_FLAT_NAME)", False,
              f'{overlong_prefix!r} + seq should have raised '
              f'ValueError but did not')
    except ValueError:
        check("over-length flat name is rejected (module's own guard, "
              "at its own current MAX_FLAT_NAME)", True)


def main():
    graph, put_targets = cm.build_graph()
    tops = cm.toplevel_manifests(graph, put_targets)
    blobs = derive_putbin_blobs(graph)

    print(f'[check-stagebin] {len(blobs)} distinct putbin blob(s) '
          f'derived from the graph: {blobs}')

    any_missing = check_real_blobs(graph, blobs)
    if not any_missing:
        check_real_budget(graph, tops)
    else:
        print('[check-stagebin] skipping real-budget check -- a blob is '
              'missing')

    check_overlong_name_guard()
    check_edge_cases()

    print()
    if failures:
        print(f'[check-stagebin] FAIL: {len(failures)} check(s) failed:')
        for f in failures:
            print(f'    {f}', file=sys.stderr)
        return 1
    print('[check-stagebin] PASS: stage_putbin.py round-trips all '
          'derived putbin blobs byte-exact (Python -> Python only -- no '
          'assembler has consumed this HEX output, see the module '
          'docstring), every emitted line is <=64 chars with a HEX '
          'opcode and an all-hex-digit even-length operand, flat names '
          'are unique and ProDOS-legal, PUT lines name '
          f'{DIR_PREFIX} explicitly, and the real per-unit budget '
          f'(stripped manifest + use + largest put, computed from the '
          f'put/use/putbin graph) fits the {BUFFER_CEILING}-byte buffer '
          'with headroom to spare')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
