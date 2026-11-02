#!/usr/bin/env python3
"""Build build/nas-real.po -- the check-nas-real L2->L3 gate image
(docs/AS-PLASMA.md): nas assembling a REAL maux util (`pwd`) plus its
FULL recursive PUT closure, not a self-contained fixture.

WHY `pwd`. Of the liba-using utils (echo, pwd -- true/false do not
exist in this tree), `pwd` has the SMALLER closure: it needs
inc/{zp,stdio,startup,mli}.equ + liba/{string,stdio,stdiofl,print,
syscalls,libabss}.s + inc/{mm.procbank,sc.proc,
sc.file,sc.fd}.equ -- 14 dependency files, no argv.s (echo's
closure is a strict superset, since echo additionally PUTs
liba/argv.s). Smallest closure first, per the task.

WHY THE PUT LINES ARE REWRITTEN. maux's own kernel does NOT resolve
".." for an ordinary file open -- only `cd` gets that (PRC_DOTDOT,
src/kernel/procfd.s's own comment: "Scope cost: only `cd` itself gets
'..' -- a plain `cat ../x` does not, since THAT would need per-call
resolution here, which is exactly the code path that proved
unreliable"). PRC_ABSPATH prepends the process cwd to a relative
operand VERBATIM (no dot-dot collapsing) and hands the composed string
straight to ProDOS's OPEN, which has no ".." concept at all -- so
`put ../../inc/zp.equ` opened literally, from any cwd, cannot resolve on
a mounted ProDOS volume. build_maux_src_image.py hit exactly this wall
for real Merlin and solved it the same way real Merlin's own manual
sanctions ("PUT accepts full ProDOS pathnames"): flatten every PUT
target to a short ProDOS-legal leaf name and REWRITE the source's PUT
lines to absolute paths. This script does the identical transform for
nas -- reusing build_maux_src_image.py's flat_name()/assign_flat_names()
(OVERRIDE_NAMES already has the four `inc/*.equ` files' names;
liba/*.equ|.s get freshly generated 'L'-prefixed names) so the flat
namespace stays the ONE place that mapping is derived, not re-invented
here (HACKING.md's "Knowing a house tool exists" rule).

nas's own PUT/USE splice (buildputpath, src/asm/nas.pla) copies the
operand VERBATIM (up to 28 chars) and appends ".S" if it has no '.' --
MEASURED against merlin32, the same rule real Merlin uses (see
build_maux_src_image.py's "WHY FLAT NAMES" note) -- so the rewritten
operand is a BARE absolute path with no extension
(`/mnt/MAUX/PLLIB/<FLATNAME>`), and the physical file is staged as
`<FLATNAME>.S`. All flat names here are <=9 chars, so
`/mnt/MAUX/PLLIB/` (13 chars) + name stays well under nas's 28-char
buildputpath cap.

`dsk`/`typ` lines are left UNTOUCHED: both are parsed-and-ignored,
byte-inert directives in nas (measured against merlin32 the same way,
task #21) -- pwd.s's own `dsk ../../build/pwd.bin` never resolves a
path in nas at all, so it needs no rewrite.

Modeled directly on build_nas_image.py (same play-image + rt + PLLIB
staging for plasma/RT/ARGS/FILEIO/NAS).
"""
import os
import re
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_maux_src_image as bmsi  # noqa: E402

PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'nas-real.po')
PLASMA_BIN = os.path.join(ROOT, 'build', 'plasma.bin')
RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
ARGS_MOD = os.path.join(ROOT, 'build', 'args.mod')
FILEIO_MOD = os.path.join(ROOT, 'build', 'fileio.mod')
NAS_MOD = os.path.join(ROOT, 'build', 'nas.mod')
VOL = 'MAUX'
LIBDIR = f'/mnt/{VOL}/PLLIB'
RT_PATH = f'/mnt/{VOL}/PLRT'

UNIT_PATH = 'src/bin/pwd.s'          # relative to ROOT
UNIT_STAGED_NAME = 'PWD.S'           # the unit's own staged leaf name

# The unit's full recursive PUT closure (verified by hand: none of
# these 14 files themselves `put`/`use` anything further -- a single-
# level splice, matching nas's own single-level PUT/USE model).
DEP_FILES = [
    'inc/mm.procbank.equ',
    'inc/sc.proc.equ',
    'inc/sc.file.equ',
    'inc/sc.fd.equ',
    'inc/zp.equ',
    'inc/stdio.equ',
    'inc/startup.equ',
    'inc/mli.equ',
    'src/liba/string.s',
    'src/liba/stdio.s',
    'src/liba/stdiofl.s',
    'src/liba/print.s',
    'src/liba/syscalls.s',
    'src/liba/libabss.s',
]

PUT_RE = re.compile(r'^([ \t]+)(put|use)([ \t]+)(\S+)', re.IGNORECASE)


def rewrite_put_lines(text, names):
    """Rewrite every `put`/`use` operand in UNIT_PATH's source to an
    absolute /mnt/MAUX/PLLIB/<FLATNAME> path (bare, no extension -- nas
    appends '.S' itself, same rule as real Merlin). `dsk`/`typ` lines
    are left completely alone (nas never resolves a path for either)."""
    out = []
    for line in text.split('\n'):
        m = PUT_RE.match(line)
        if m:
            target = os.path.normpath(
                os.path.join(os.path.dirname(UNIT_PATH), m.group(4)))
            if target in names:
                indent, kw = m.group(1), m.group(2)
                out.append(f'{indent}{kw}{m.group(3)}/mnt/{VOL}/PLLIB/'
                           f'{names[target]}')
                continue
            raise AssertionError(
                f'{UNIT_PATH}: put/use target {m.group(4)!r} -> '
                f'{target!r} has no assigned flat name -- closure list '
                f'is incomplete')
        out.append(line)
    return '\n'.join(out)


def main():
    needed = [
        (PLAY_IMG, 'play image'),
        (PLASMA_BIN, 'plasma.bin (the VM seed)'),
        (RT_MOD, 'rt.mod (make build/rt.mod)'),
        (ARGS_MOD, 'args.mod (make build/args.mod)'),
        (FILEIO_MOD, 'fileio.mod (make build/fileio.mod)'),
        (NAS_MOD, 'nas.mod (make build/nas.mod)'),
    ]
    for path, label in needed:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    for relp in [UNIT_PATH] + DEP_FILES:
        if not os.path.exists(os.path.join(ROOT, relp)):
            print(f'error: missing source file: {relp}', file=sys.stderr)
            return 2

    mods = {}
    for nm, pth in (('ARGS', ARGS_MOD), ('FILEIO', FILEIO_MOD),
                    ('NAS', NAS_MOD), ('RT', RT_MOD)):
        with open(pth, 'rb') as f:
            mods[nm] = f.read()
        if nm == 'RT':
            if mods[nm][0] != 0x4C:
                print(f'error: {pth} is not a flat rt (no JMP at $2000)',
                      file=sys.stderr)
                return 2
        elif mods[nm][2:4] != b'\x02\x65':
            print(f'error: {pth} lacks the $6502 module magic',
                  file=sys.stderr)
            return 2
        elif mods[nm][10:12] == b'\x00\x00':
            print(f'error: {pth} has a zero init word', file=sys.stderr)
            return 2

    with open(PLASMA_BIN, 'rb') as f:
        seedbin = f.read()

    names = bmsi.assign_flat_names(DEP_FILES)
    for relp in DEP_FILES:
        assert len(names[relp]) <= 13, f'{relp}: {names[relp]!r} too long'
        full = f'/mnt/{VOL}/PLLIB/{names[relp]}'
        assert len(full) <= 28, f'{relp}: {full!r} exceeds nas\'s 28-char cap'

    with open(os.path.join(ROOT, UNIT_PATH), errors='replace') as f:
        unit_src = f.read()
    unit_rewritten = rewrite_put_lines(unit_src, names)
    assert len(unit_rewritten.split('\n')) == len(unit_src.split('\n')), \
        f'{UNIT_PATH}: rewrite changed line count'
    unit_bytes = convert.text_from_host(unit_rewritten.encode('latin-1'))

    dep_bytes = {}
    total_dep_raw = 0
    for relp in DEP_FILES:
        with open(os.path.join(ROOT, relp), 'rb') as f:
            raw = f.read()
        dep_bytes[relp] = convert.text_from_host(raw)
        total_dep_raw += len(raw)

    shutil_copy_needed = not os.path.exists(OUT_IMG) or True
    import shutil
    shutil.copyfile(PLAY_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    try:
        # This image is play.po plus a ~115 KB source closure, and it
        # never invokes man(1): check_nas_real.py drives `cd`, `plasma
        # NAS`, `echo` and one `ls` used only as a flush nudge. The 63
        # not-applicable stub pages plus the real ones are ~110 blocks
        # of dead weight here, and holding them made ordinary growth in
        # play-image utilities (14 of them gained POSIX flags on
        # 2026-09-17) spend THIS gate's headroom: the volume filled and
        # the build died with "no free blocks on volume". Dropped here,
        # not from the play image, where man is the point.
        man_dir = '/usr/man'
        for leaf in prodos.listdir(man_dir):
            prodos.remove(f'{man_dir}/{leaf}')
        prodos.rmdir(man_dir)
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/plasma', seedbin, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(RT_PATH, mods['RT'], file_type=0xFE,
                     aux_type=0x0000, overwrite=True)
        prodos.mkdir(LIBDIR)
        for nm in ('ARGS', 'FILEIO', 'NAS'):
            prodos.write(f'{LIBDIR}/{nm}', mods[nm], file_type=0xFE,
                         aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/{UNIT_STAGED_NAME}', unit_bytes,
                     file_type=0x04, aux_type=0x0000, overwrite=True)
        for relp in DEP_FILES:
            leaf = f'{names[relp]}.S'
            prodos.write(f'{LIBDIR}/{leaf}', dep_bytes[relp],
                         file_type=0x04, aux_type=0x0000, overwrite=True)
        entries = sorted(e.name for e in prodos.scandir(LIBDIR))
    finally:
        prodos.unmount(VOL)

    print(f'[build-nas-real] unit: {UNIT_PATH} -> {LIBDIR}/'
          f'{UNIT_STAGED_NAME} ({len(unit_bytes)} B)')
    print(f'[build-nas-real] {len(DEP_FILES)} dependency file(s), '
          f'{total_dep_raw} B raw total:')
    for relp in DEP_FILES:
        print(f'  {names[relp] + ".S":<14} <- {relp} '
              f'({len(dep_bytes[relp])} B)')
    print(f'[build-nas-real] {LIBDIR} holds {entries}')
    print(f'[build-nas-real] {RT_PATH} staged (rt {len(mods["RT"])} B, '
          f'flat)')
    print(f'[build-nas-real] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
