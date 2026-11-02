#!/usr/bin/env python3
"""build_maux_src_image.py -- put the maux tree on a ProDOS volume that real
Merlin-8 can assemble from, comment-stripped, and (optionally) add capacity
probes.

    python3 scripts/build_maux_src_image.py [--probes]

WHY A SECOND VOLUME. The Merlin source disk (build/merlinsrc.po) is full --
Merlin's own sources fill an 800K volume. maux's sources are another ~234 KB,
so they get their own volume, mounted as unit 2, and the PUT lines use
absolute /mnt/MAUXSRC/ paths.

WHY FLAT NAMES. maux uses relative paths (`put ../kernel/entry.s`) that mean
nothing to ProDOS. So each module gets a flat, prefixed, ProDOS-legal LEAF
name (see the subdirectory note below for why files also live one directory
down from /mnt/MAUXSRC/) and the PUT lines are rewritten to match. Merlin's PUT
appends `.S` itself, so the directive names the file WITHOUT the suffix.
(Originally this also worked around a2til#13, "cannot currently create
directories ProDOS will accept" -- stale as of this rewrite, see below.)

WHY STRIPPED. 46% of this tree is comment-only lines, and real Merlin-8 holds
the file it is assembling as TEXT in a 41,215-byte buffer
(learning:01M051EM2HQ3ZVJTR1W9P3G86J) -- a comment costs the same as code
there. docs/PLAN.md's S9 note and docs/DEMOS.md section 3a: the MASTER tree
keeps every comment (that's what makes it readable); only the form staged
here, onto the self-hosting disk image, gets stripped. scripts/strip_comments.py
is the one place the stripping rule lives -- see its header for the exact
rule, why blank-substitution rather than deletion, and the invariants it
proves on every call. This is one of THREE consumers of that module (the
others: check_dialect.py's budget gate, and a differential sed gate);
importing it here rather than re-deriving the rule is the whole point.

WHY A SUBDIRECTORY FOR DEPENDENCIES. ProDOS's VOLUME directory is a hard
4-block structure that never grows (a2til's own prodos.py: "a full
subdirectory is extended; the volume directory raises") -- about 51 file
slots, full stop. Two units' graph-derived dependency set is 52 files
before either unit's own manifest, which overflows the root outright
(measured 2026-08-23: `ValueError: volume directory is full` on file 53).
a2til's root README documents `mkdir`/subdirectories as a real, supported
ProDOS operation (HACKING.md's "read the tool before hand-rolling" rule --
the ORIGINAL "WHY FLAT NAMES" note above cites a2til#13, "cannot currently
create directories ProDOS will accept", which is now stale: mkdir works).
A ProDOS SUBdirectory has no such 4-block ceiling -- it extends like a
file. So dependency modules are staged in /mnt/MAUXSRC/SRC/ (still flat names
inside it -- Merlin's PUT still needs a legal leaf name, and the existing
OVERRIDE_NAMES table stays meaningful), and only the two unit manifests
plus their DSK object targets stay at the /mnt/MAUXSRC/ root, where check_dual.py
already expects PTEST and OBJ. The Merlin 8/16 manual is explicit that PUT
accepts full ProDOS pathnames ("Slot and drive parameters are NOT
acceptable... you MUST use pathnames" -- learning:01M050TRV68DY9GBARSDRX9B1W's
artifact), so `PUT /mnt/MAUXSRC/SRC/NAME` is exactly the form real Merlin
already documents supporting.

WHY GRAPH-DERIVED STAGING, NOT A HAND-LIST. Every file a staged UNIT (see
UNITS below) needs is derived from scripts/check_manifests.py's build_graph()
put/use edges -- the same machinery check_dialect.py imports
(`import check_manifests as cm`). A hand-maintained "files this image needs"
list is exactly the shape that went stale THREE separate times in one day
(2026-08-19/20, see check_manifests.py's own docstring) and HACKING.md's
"Knowing a house tool exists" entry: a fourth instance, of a DIFFERENT
hand-maintained list, in this same file. Flat NAMES still need a stable,
human-legible table for files already staged (check_dual.py and anything
else naming a staged file by its flat name must not break) -- that part
stays hand-maintained deliberately, as OVERRIDE_NAMES, with new files
getting a generated name. See flat_name() below.

WHAT THIS IS FOR. Task #7: having real Merlin judge this tree rather than
inferring what it would say. It is also how the source-buffer ceiling was
measured -- see --probes and docs/TOOLCHAIN.md.
"""
import os
import re
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_manifests as cm  # noqa: E402
import strip_comments as sc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.path.join(ROOT, 'build', 'mauxsrc.po')
BLOCKS = 1600                                   # 800K
BUFFER = 0xAA00 - 0x0901                        # 41215, Merlin's source buffer
SRCDIR = 'SRC'                                  # subdirectory for dependency
                                                 # modules; see WHY A
                                                 # SUBDIRECTORY above

# ---------------------------------------------------------------------------
# UNITS -- the top-level manifests staged onto the image. Each is a real
# compilation unit real Merlin-8 can be pointed at: `L/MAUXSRC/<name>` then
# `ASM`. Each unit gets its OWN `dsk` target so two units' object files
# never collide -- check_dual.py reads /mnt/MAUXSRC/OBJ by that exact literal
# path, so PTEST's target is not renamed here.
# ---------------------------------------------------------------------------
# DUAL (2026-09-12): the unit check_dual.py assembles under real Merlin-8.
# It WAS PTEST -- the biggest PUT chain, chosen to prove the worst case
# of the SOURCE-buffer budget -- until the VT102 console work's +36 kernel
# globals ran Merlin-8's SYMBOL TABLE out ("Memory full in line: 217
# >826", the editor prompt, no "Errors:" banner -- the gate read it as a
# hang). The symbol table is the OTHER capacity limit docs/TOOLCHAIN.md
# names: 9 + sum(namelen + 4) over every global label and equate the
# unit defines, and the measured ceiling is between 17,478 B (passed,
# 048e792) and 17,700 B (failed, 128f4ea). The kernel alone is ~16.5 KB
# of it, so the unit that proves KERNEL byte-identity should carry the
# fewest non-kernel symbols: pipewraptest, the leanest kernel manifest
# (16,975 B on 2026-09-12). PTEST stays staged for the source budget
# printout. MERLIN8_SYMTAB_CEIL below fails the build on the host the
# moment any unit crosses it, so the next growth is caught here, not by
# a silent Merlin.
MERLIN8_SYMTAB_CEIL = 17400
UNITS = [
    {'name': 'DUAL',  'path': 'src/test/pipewraptest.s', 'obj': 'OBJ'},
    {'name': 'PTEST', 'path': 'src/test/processtest.s', 'obj': 'POBJ'},
    {'name': 'DIFF',  'path': 'src/bin/diff.s',          'obj': 'DIFFOBJ'},
]

# flat ProDOS name <- source path, for every file that is ALREADY staged
# under a chosen name. check_dual.py and anything else that names a staged
# file by its flat name must not break, so these are never regenerated.
# New files -- e.g. src/bin/diff.s's liba/* dependencies, added when DIFF
# joined UNITS -- get a name generated by flat_name() below instead of an
# entry here. Historical per-entry notes (why files were split the way they
# were) are preserved from the original hand-maintained MODULES table.
OVERRIDE_NAMES = {
    # THE `Xtest.s` / `Xtestb.s` PAIRS (2026-08-28). flat_name() derives
    # from the basename and truncates, so a harness and its own back-half
    # generate the SAME name -- `bankcopytest.s` and `bankcopytestb.s`
    # both give TBANKCOPYTEST. That never surfaced while only PTEST's and
    # DIFF's closures were staged; it fires the moment the WHOLE tree is,
    # which is what a big enough volume makes possible. Only the `b`
    # halves get entries: the base names stay exactly as generated, so
    # nothing already staged (check_dual names files by flat name) moves.
    'TBANKCPYTSTB':  'src/test/bankcopytestb.s',
    'TFILEPROCTSB':  'src/test/fileproctestb.s',
    'TPIPEWRAPTSB':  'src/test/pipewraptestb.s',
    # syscall.equ/errno.equ split (2026-08-20, docs/SELFHOST-
    # CONVERSION.md phase 1): the combined ~9.8KB was PUT whole by
    # every compilation unit; split per concern from a reference-set
    # scan the same way memmap.equ was, below.
    'ISCPROC':   'inc/sc.proc.equ',
    'ISCSTAT':   'inc/sc.status.equ',
    'ISCFILE':   'inc/sc.file.equ',
    'ISCFD':     'inc/sc.fd.equ',
    'ISCDEVFD':  'inc/sc.devfd.equ',
    'ISCFDACT':  'inc/sc.fdact.equ',
    'IERRKRN':   'inc/errno.krn.equ',
    'IERRSPWN':  'inc/errno.spawn.equ',
    # memmap.equ split (2026-08-20, docs/SELFHOST-CONVERSION.md phase 1):
    # the old 35888B monolith was PUT by every unit regardless of use --
    # PUT never reclaims (learning:01M0CC62FZ351EBXCAAKX52KAJ), so its
    # full size was charged against every single assembly's window. Split
    # per concern, derived from which files actually reference each
    # symbol -- see docs/MEMMAP.md's own header note for the grouping.
    'IMMPBANK':  'inc/mm.procbank.equ',
    'IMMPBNK2':  'inc/mm.procbnk2.equ',
    'IMMHW':     'inc/mm.hw.equ',
    'IMMMLI':    'inc/mm.mli.equ',
    'IMMMBUF':   'inc/mm.mlibuf.equ',
    'IMMANNEX':  'inc/mm.annex.equ',
    'IMMANNX2':  'inc/mm.annex2.equ',
    # IMMMAIN is DEAD against today's UNITS (neither PTEST's nor DIFF's
    # put/use closure reaches it) -- kept, not deleted: it is still
    # put/used for real, by src/check.memmap.s and
    # src/test/syscalltest.s, neither of which has joined UNITS yet.
    # Deleting it would only re-surface as a fresh omission (instance (c)'s
    # shape) the day either of those becomes a staged unit.
    'IMMMAIN':   'inc/mm.main.equ',
    # Phase-1 conversion includes (2026-08-20). A file the top-level
    # manifest PUTs must be staged here or real Merlin cannot see it --
    # same class of omission as build_ascore_image.py's PUT_INCLUDED
    # missing LINKER.S.
    'IBANKCPY':  'inc/bankcopy.equ',
    'IENTFRM':   'inc/entry.frame.equ',
    'ISCHED':    'inc/sched.equ',
    'IBNKPROBE': 'inc/bankprobe.equ',
    'IMLICONST': 'inc/mli.const.equ',
    'IULTRATRM': 'inc/ultraterm.equ',
    'KENTRY':    'src/kernel/entry.s',
    'KENTRY2':   'src/kernel/entry2.s',
    'KFFPAGE':   'src/kernel/ffpage.s',
    'KSCHED':    'src/kernel/sched.s',
    'KSCHED2':   'src/kernel/sched2.s',
    'KBANKCOPY': 'src/kernel/bankcopy.s',
    'KPROCESS':  'src/kernel/process.s',
    'KPROCFILE': 'src/kernel/procfile.s',
    'KPROCFIL2': 'src/kernel/procfile2.s',
    'KPROCFIL3': 'src/kernel/procfile3.s',
    'KPROCFIL5': 'src/kernel/procfile5.s',
    'KTTY':      'src/kernel/tty.s',
    'KTTY2':     'src/kernel/tty2.s',
    'KTTY5':     'src/kernel/tty5.s',
    'KTTY6':     'src/kernel/tty6.s',
    'KTTY7':     'src/kernel/tty7.s',
    'KTTY8':     'src/kernel/tty8.s',
    'KULTRATERM': 'src/kernel/ultraterm.s',
    'KULTRATERM2': 'src/kernel/ultraterm2.s',
    'KPROCSPWN': 'src/kernel/procspawn.s',
    'KPROCSPWN2': 'src/kernel/procspawn2.s',
    'KPROCFD':   'src/kernel/procfd.s',
    'KPROCFD2':  'src/kernel/procfd2.s',
    'KLAZYFREE': 'src/kernel/lazyfree.s',
    'KPROCFORK': 'src/kernel/procfork.s',
    # KMOUSE/KMLI/KTIMER/KBANKPROBE are DEAD against today's UNITS
    # (PTEST/DIFF) the same way IMMMAIN above is: each is still a real
    # put/use target -- KMOUSE and KTIMER via src/test/playtest.s and the
    # three sched.*.s units, KMLI via src/test/prodos.spike.s,
    # KBANKPROBE via src/test/probetest.s -- none of which is in UNITS
    # yet. Kept for the same reason: a pending unit needs them.
    'KMOUSE':    'src/kernel/mouse.s',
    'KMLI':      'src/kernel/mli.s',
    'KTIMER':    'src/kernel/timer.s',
    'KBANKPROBE': 'src/kernel/bankprobe.s',
    # image bodies: PTEST's own manifest PUTs this last
    'TPTESTB':   'src/test/processtestb.s',
}
OVERRIDE_BY_PATH = {v: k for k, v in OVERRIDE_NAMES.items()}

# Directory -> flat-name prefix letter, for files with no OVERRIDE_NAMES
# entry. Matches scripts/shrink_source.py's TREE_PREFIX exactly (same
# convention, independently useful in both places).
TREE_PREFIX = {'kernel': 'K', 'liba': 'L', 'bin': 'B', 'test': 'T',
               'inc': 'I'}


def flat_name(relpath):
    """Deterministic ProDOS-legal flat name for a file with no
    OVERRIDE_NAMES entry: <dir-prefix letter><STEM>, letters/digits only,
    starting with a letter, truncated to 13 characters so the '.S' suffix
    Merlin's PUT appends itself still fits ProDOS's 15-character ceiling.
    An `.equ` file gets a trailing 'Q' so a same-stem `.s`/`.equ` pair in
    the same directory (src/liba/mli.s + inc/mli.equ, the one such
    pair in this tree today) cannot collide."""
    parent = os.path.basename(os.path.dirname(relpath))
    prefix = TREE_PREFIX.get(parent, 'X')
    stem, ext = os.path.splitext(os.path.basename(relpath))
    stem = re.sub(r'[^A-Za-z0-9]', '', stem).upper()
    if ext.lower() == '.equ':
        stem += 'Q'
    name = (prefix + stem)[:13]
    assert re.match(r'^[A-Z][A-Z0-9]*$', name), \
        f'{relpath}: generated flat name {name!r} is not ProDOS-legal'
    return name


def assign_flat_names(files):
    """path (relative to ROOT) -> flat ProDOS name, for every file in
    `files`. OVERRIDE_NAMES wins where it has an entry; every other file
    gets flat_name(). Asserts every OVERRIDE_NAMES entry is itself
    ProDOS-legal and that no two DIFFERENT files ever end up sharing a
    name."""
    claimed = {}                      # flat name -> owning relpath
    paths_claimed = {}                # relpath -> owning flat name
    for name, path in OVERRIDE_NAMES.items():
        assert re.match(r'^[A-Z][A-Z0-9]*$', name) and len(name) <= 13, \
            f'OVERRIDE_NAMES[{name!r}] ({path}) is not ProDOS-legal'
        # `name not in claimed` can never fire here -- OVERRIDE_NAMES.items()
        # iterates a dict, whose keys are unique by construction. The real
        # hazard is the OTHER direction: two DIFFERENT names claiming the
        # SAME path, which OVERRIDE_BY_PATH's {v: k for k, v in ...} would
        # then silently resolve to whichever entry iterates last, dropping
        # the other name with no error at all.
        assert path not in paths_claimed, \
            (f'OVERRIDE_NAMES has two entries for {path!r}: '
             f'{paths_claimed.get(path)!r} and {name!r} both name it -- '
             f'OVERRIDE_BY_PATH would silently keep only one')
        claimed[name] = path
        paths_claimed[path] = name

    names = {}
    for relp in sorted(files):
        if relp in OVERRIDE_BY_PATH:
            name = OVERRIDE_BY_PATH[relp]
        else:
            name = flat_name(relp)
            if name in claimed and claimed[name] != relp:
                raise AssertionError(
                    f'generated flat name {name!r} for {relp!r} collides '
                    f'with {claimed[name]!r} -- add an OVERRIDE_NAMES '
                    f'entry for one of them')
            claimed[name] = relp
        names[relp] = name
    return names


def hi(text):
    """Merlin source is high-bit ASCII with CR line endings."""
    return bytes((ord(c) | 0x80) if c != '\n' else 0x8D
                 for c in text.replace('\n', '\r'))


def rewrite(path, names, dsk_target):
    """Rewrite one unit's put/use/dsk operands for the flat ProDOS
    namespace and its own object-file target. `names` maps every other
    staged file's ROOT-relative path to its flat name; those files live in
    /mnt/MAUXSRC/SRC/ (see WHY A SUBDIRECTORY above), while the unit's own DSK
    object target stays at the /mnt/MAUXSRC/ root."""
    out = []
    for line in open(os.path.join(ROOT, path), errors='replace').read().split('\n'):
        m = re.match(r'^([ \t]+)(put|use)\s+(\S+)', line, re.I)
        if m:
            target = os.path.normpath(os.path.join(os.path.dirname(path),
                                                   m.group(3)))
            if target in names:
                out.append(f' PUT /mnt/MAUXSRC/{SRCDIR}/{names[target]}')
                continue
        if re.match(r'^[ \t]+dsk\s', line, re.I):
            out.append(f' DSK /mnt/MAUXSRC/{dsk_target}')
            continue
        out.append(line)
    return '\n'.join(out)


def unit_budget(graph, top, use_stripped):
    """(resident, largest_put_size, largest_put_relpath, total) for one
    top-level manifest, against the SOURCE TREE's own files (not the
    staged/rewritten copies) -- same shape as check_dialect.py's
    check_budget(), reused here so this printout and that gate cannot
    silently disagree about what the ceiling math is."""
    def size(p):
        return len(sc.strip_file(p)) if use_stripped else os.path.getsize(p)
    edges = graph[top]
    manifest = size(top)
    use_sz = sum(size(t) for d, t, _ in edges if d == 'use' and os.path.exists(t))
    resident = manifest + use_sz
    worst, worst_f = 0, '-'
    for d, t, _ in edges:
        if d == 'put' and os.path.exists(t):
            s = size(t)
            if s > worst:
                worst, worst_f = s, cm.rel(t)
    return resident, worst, worst_f, resident + worst


def unit_symtab(graph, top):
    """Merlin-8 symbol-table bytes for one unit: 9 + sum(len(name)+4) over
    every GLOBAL label/equate in the unit's closure (locals are dropped at
    the next global, so they do not accumulate). The formula is measured
    (learning:01M0CC62FZ351EBXCAAKX52KAJ); the ceiling is empirical, see
    MERLIN8_SYMTAB_CEIL."""
    import re
    files = [top] + sorted(cm.closure(graph, top))
    n = tot = 0
    for f in files:
        if not os.path.exists(f):
            continue
        for line in open(f, errors='replace'):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', line)
            if m:
                n += 1
                tot += len(m.group(1)) + 4
    return n, 9 + tot


def add_probes(vol):
    """Graduated filler files, to measure the source-buffer ceiling.
    Deliberately NOT run through strip_comments: their entire content IS
    comment lines whose count is chosen to land on an exact byte total,
    which is the thing being probed -- stripping them would blank the
    padding and defeat the probe."""
    line = '* ' + 'X' * 58                      # 60 chars, inside the limit
    for kb in (36, 39, 41, 43):
        n = (kb * 1024) // 61
        vol.write_file(f'/mnt/MAUXSRC/F{kb}.S', hi('\r'.join([line] * n + [' RTS', ''])),
                       file_type=0x04, aux_type=0, overwrite=True)
        vol.write_file(f'/mnt/MAUXSRC/P{kb}.S',
                       hi('\r'.join([' LST OFF', ' ORG $8000',
                                     f' PUT /mnt/MAUXSRC/F{kb}', ''])),
                       file_type=0x04, aux_type=0, overwrite=True)
        print(f'  probe F{kb}.S ~{kb} KB')


def main(argv):
    if os.path.exists(IMAGE):
        os.remove(IMAGE)
    os.makedirs(os.path.dirname(IMAGE), exist_ok=True)
    a2til.prodos.create(IMAGE, name='MAUXSRC', blocks=BLOCKS)
    vol = a2til.open_image(IMAGE)
    vol.mkdir(f'/mnt/MAUXSRC/{SRCDIR}')

    graph, put_targets = cm.build_graph()
    unit_abspaths = [os.path.join(ROOT, u['path']) for u in UNITS]

    # Graph-derived staging (never hand-listed): every file EITHER unit's
    # transitive put/use chain needs, unioned, minus the unit top-levels
    # themselves (those are staged separately below, rewritten).
    dep_files = set()
    for top in unit_abspaths:
        dep_files |= cm.closure(graph, top)
    for top in unit_abspaths:
        dep_files.discard(top)
    dep_relpaths = sorted(cm.rel(f) for f in dep_files)

    names = assign_flat_names(dep_relpaths)

    total_raw = total_stripped = 0
    print(f'[maux-src-image] {len(dep_relpaths)} dependency file(s), '
          f'graph-derived from {len(UNITS)} unit(s):')
    for relp in dep_relpaths:
        name = names[relp]
        text = open(os.path.join(ROOT, relp), errors='replace').read()
        raw_bytes = hi(text)
        stripped_text = sc.strip_text(text, name=relp)
        stripped_bytes = hi(stripped_text)
        assert len(stripped_text.split('\n')) == len(text.split('\n')), \
            f'{relp}: strip changed line count'
        vol.write_file(f'/mnt/MAUXSRC/{SRCDIR}/{name}.S', stripped_bytes,
                       file_type=0x04, aux_type=0, overwrite=True)
        total_raw += len(raw_bytes)
        total_stripped += len(stripped_bytes)
        saved = len(raw_bytes) - len(stripped_bytes)
        print(f'  {name + ".S":<14} {len(raw_bytes):>7} -> {len(stripped_bytes):>7} '
              f'(-{saved:>6})  <- {relp}')

    print(f'\n[maux-src-image] {len(UNITS)} unit manifest(s), '
          f'rewritten then stripped (the two transforms touch disjoint '
          f'line sets -- rewrite only touches put/use/dsk directive '
          f'lines, which by definition are never comment-only -- so '
          f'order does not matter; rewrite runs first here):')
    for u in UNITS:
        relp = u['path']
        original = open(os.path.join(ROOT, relp), errors='replace').read()
        rewritten = rewrite(relp, names, u['obj'])
        assert len(rewritten.split('\n')) == len(original.split('\n')), \
            f'{relp}: rewrite changed line count'
        stripped = sc.strip_text(rewritten, name=relp)
        assert len(stripped.split('\n')) == len(original.split('\n')), \
            f'{relp}: strip-after-rewrite changed line count'
        data = hi(stripped)
        raw_len = len(hi(original))
        vol.write_file(f'/mnt/MAUXSRC/{u["name"]}.S', data, file_type=0x04,
                       aux_type=0, overwrite=True)
        total_raw += raw_len
        total_stripped += len(data)
        saved = raw_len - len(data)
        print(f'  {u["name"] + ".S":<14} {raw_len:>7} -> {len(data):>7} '
              f'(-{saved:>6})  <- {relp} (put/use/dsk rewritten)')

    if '--probes' in argv:
        print()
        add_probes(vol)

    vol.flush()
    print(f'\n[maux-src-image] {IMAGE}')
    print(f'  volume total: {total_raw / 1024:.1f} KB raw -> '
          f'{total_stripped / 1024:.1f} KB stripped '
          f'(-{(total_raw - total_stripped) / 1024:.1f} KB, '
          f'{100 * (total_raw - total_stripped) / total_raw:.1f}%)')

    print(f'\n[maux-src-image] per-unit source-buffer budget '
          f'(resident top-level + SUM(use) + LARGEST put <= {BUFFER}, '
          f'learning:01M0CC62FZ351EBXCAAKX52KAJ):')
    for u in UNITS:
        top = os.path.join(ROOT, u['path'])
        for label, stripped in (('raw', False), ('stripped', True)):
            resident, worst, worst_f, total = unit_budget(graph, top, stripped)
            verdict = 'OK' if total <= BUFFER else 'OVER'
            print(f'  {u["name"]:<6} {label:<9} resident {resident:>6} + '
                  f'largest put {worst:>6} ({worst_f}) = {total:>6}  '
                  f'[{verdict}, ceiling {BUFFER}]')
            if total > BUFFER:
                print(f'    *** {u["name"]} ({label}) is '
                      f'{total - BUFFER} bytes OVER the source buffer -- '
                      f'real Merlin will die with "56 MEMORY IN USE" if '
                      f'assembled in this form. Not failing the build; '
                      f'the TL decides.')
    print(f'\n[maux-src-image] per-unit Merlin-8 SYMBOL-TABLE budget '
          f'(9 + sum(len(name)+4) over globals <= {MERLIN8_SYMTAB_CEIL}, '
          f'measured ceiling 17478 ok / 17700 full, 2026-09-12):')
    over = []
    for u in UNITS:
        top = os.path.join(ROOT, u['path'])
        n, sym = unit_symtab(graph, top)
        verdict = 'OK' if sym <= MERLIN8_SYMTAB_CEIL else 'OVER'
        print(f'  {u["name"]:<6} {n:>5} globals  {sym:>6} B  [{verdict}]')
        if sym > MERLIN8_SYMTAB_CEIL and u['name'] == 'DUAL':
            over.append(u['name'])
    if over:
        print(f'[maux-src-image] NOTE: {over} past the Merlin-8 symbol table '
              f'-- real Merlin stops with "Memory full" and check-dual reads '
              f'it as a hang. check-dual is PARKED (Makefile) until nas; '
              f'this is a report, not a failure.')

    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
