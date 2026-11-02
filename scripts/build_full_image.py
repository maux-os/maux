#!/usr/bin/env python3
"""Build build/full.po -- the release disk with all the fruit
(`make full-image`, docs/FULLDISK.md, SITE.md D2).

NOT a third image builder. It is the composition of the two there
already are:

  * build_nas_librel_image.grow_play_image() replays build/play.po's
    whole tree onto a 65,535-block volume (boot blocks spliced), and
    the same module's self-make composer stages the native world --
    every nas/ld assembly and link and the MAKEFILE that drives them --
    re-pointed (configure_full) from its /tmp test layout to
    /usr/src/maux, where `cd /usr/src/maux; make` finds it;
  * build_play_image supplies the roster rules and the timestamp
    normalisation (IMAGE_TIMESTAMP); this file adds only what neither
    stages: the five PLAY_EXCLUDE programs and plasm in /bin, /usr/inc,
    /usr/lib/LIBA, /usr/src/examples and the real NuFX archives in DEMO.

THE FILE IS build/full.po, NOT build/maux.po (the brief's name).
build/maux.po is already the 800-block kernel image `make image`
builds and check-boot, check-mame and mcp_drive.py all boot; reusing
the name would have made the two overwrite each other. The release
bundle still names its disk maux-VERSION.po.

THE ONE EMULATOR STEP. /usr/lib/LIBA holds liba as REL objects, and the
only assembler that makes them is nas, which runs only on maux. So the
builder boots the staged image ONCE under verilogapple (the gates' rig,
scripts/mcp_drive.py), runs nas over every liba REL form the composer
staged, and harvests the objects. The result is cached under
build/full-liba/<hash of the staged liba sources> so the second build
of an unchanged tree does not boot anything (the determinism gate
builds twice). This is the single place `make full-image` needs
verilogapple; the day nas has a host build, it goes away.

THE BUILD TIER SKIPS IT (docs/DEPS-TIER.md, 2026-10-19: FULLDISK D1's
named trigger). The objects are committed under pinned/liba/ and
hash-locked in dependencies.lock.json; when MAUX_TIER=build the builder
reads them from there and boots nothing. The test tier still runs the
emulator, and `--check-pins` (make check-liba-pins, in the sweep) boots
nas FRESH -- never the cache -- and requires the result to equal the
pins; `--repin-liba` rewrites them after a deliberate change.

Concurrency (learning:01M2M2TYW5W09FZ6EJQZN6BKYN): the whole build is
inside imglock.publish(), so two lanes queue instead of colliding and a
reader only ever sees a complete image. a2til's mount registry is
process-global and keyed by volume name, and play.po and full.po are
BOTH named MAUX (learning:01M4DJW1APCG2SEQM16SH3MM4E): grow_play_image
reads play.po fully and unmounts it before the new volume exists, and
nothing here ever has both mounted.

Determinism (learning:01M15HP99A0W5NK3T9H8QXGW4K): a2til stamps every
write with the wall clock at minute resolution, so EVERY file this
builder adds is covered by the final normalize_image_dates() pass over
the whole volume, not only the ones copied from play.po.
"""
import hashlib
import json
import os
import re
import shutil
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)
import imglock  # noqa: E402
import build_play_image as bpi  # noqa: E402
import prodos_dates  # noqa: E402
import build_nas_librel_image as bnl  # noqa: E402
import check_manifests as cm  # noqa: E402
import pinned  # noqa: E402

OUT_IMG = os.path.join(ROOT, 'build', 'full.po')
VOL = 'MAUX'
FULL_BLOCKS = bpi.FULL_BLOCKS  # ProDOS's ceiling: a 16-bit block count
LIBA_CACHE = os.path.join(ROOT, 'build', 'full-liba')

#: Programs the Makefile builds that the release disk does NOT carry,
#: name -> reason. Empty by ruling (SITE.md D2: "all the fruit"):
#: PLAY_EXCLUDE's reason was the play volume's ~51-entry ROOT cap, and
#: /bin is a subdirectory that grows. check_manifests CHECK 8 requires
#: UTILS == shipped + FULL_EXCLUDE, both directions.
FULL_EXCLUDE = {}

#: The PLAY_EXCLUDE programs ride in /bin beside the rest.
EXTRA_BINS = [n for n in bpi._makefile_utils()
              if n in bpi.PLAY_EXCLUDE and n not in FULL_EXCLUDE]

#: the three tool names that ride in /bin beside UTILS (none is a UTILS
#: member: nas and plasm are cooked images, ld has its own rule).
FULL_EXTRA_NAMES = ('nas', 'ld', 'plasm')
NAS_CUT = os.path.join(ROOT, 'build', 'nas.cut')
LD_BIN = os.path.join(ROOT, 'build', 'ld.bin')
PLASM_CUT = os.path.join(ROOT, 'build', 'plasm.cut')
#: Dave's hello.pla cooked by plascut on the host (Makefile HELLOPLA_CUT).
HELLOPLA_CUT = os.path.join(ROOT, 'build', 'hellopla.cut')
#: The tree's copy of Dave's header, the file check-plasma-examples (D2)
#: holds byte for byte to the pinned PLASMA commit, and the one the
#: Makefile names as a full-image prerequisite.
PLASMA_CMDSYS_PLH = os.path.join(ROOT, 'src', 'plasma', 'inc', 'cmdsys.plh')
EXAMPLES_SRC = os.path.join(ROOT, 'examples')
#: XMASADV.SDK stays in the tree as a gate fixture (check-unpack,
#: check-devfs) but is NOT on the public disk: no distribution terms are
#: recorded for it (fixtures/PROVENANCE.md). DEMOPROG's are ("freely
#: distributable" per the CD notes); the asimov pair are freeware.
FIXTURES = [
    ('gem', 'DEMOPROG.SDK'),
    ('asimov', 'SLOTSCAN.SHK'), ('asimov', 'VBLSET.SHK'),
]
#: build_unpack_image.py / check_nulib2.py's convention for a staged
#: NuFX archive (docs/NUFX.md).
ARC_FTYPE = 0xE0
ARC_AUX = 0x8002

#: The kernel-private headers a USERLAND program never puts are the
#: complement of this closure in inc/. Reported, not chosen.
USER_ROOTS = ('src/bin', 'src/liba')


def full_util_names():
    """Every program the Makefile builds that this disk ships."""
    return [n for n in bpi._makefile_utils() if n not in FULL_EXCLUDE]


def user_inc_closure():
    """inc/ files reachable from src/bin/*.s and src/liba/*.s through
    the tree's own put graph (check_manifests.build_graph), and the
    inc/ files outside it. Returns (shipped, excluded) as sorted
    basenames."""
    graph, _put_targets = cm.build_graph()
    seen = set()
    for sub in USER_ROOTS:
        d = os.path.join(ROOT, sub)
        for fn in sorted(os.listdir(d)):
            if fn.endswith('.s'):
                seen |= cm.closure(graph, os.path.join(d, fn))
    incdir = os.path.join(ROOT, 'inc') + os.sep
    shipped = sorted(os.path.basename(p) for p in seen
                     if p.startswith(incdir))
    every = sorted(f for f in os.listdir(incdir) if f.endswith('.equ'))
    return shipped, [f for f in every if f not in shipped]


def maux_text(data):
    """A file a person reads: high-bit ASCII, CR line ends ($8D)."""
    out = bytearray()
    for b in data:
        if b == 0x0A:
            out.append(0x8D)
        elif b == 0x0D:
            continue
        else:
            out.append(b | 0x80)
    return bytes(out)


def read_tree(path):
    with open(path, 'rb') as f:
        return f.read()


def mkdirs(path):
    """mkdir -p over the mounted volume."""
    cur = ''
    for part in path.strip('/').split('/'):
        cur += '/' + part
        try:
            prodos.mkdir(cur)
        except FileExistsError:
            pass


class _Fs:
    """The few volume operations stage_bins() performs, so that CHECK 8
    (check_manifests.py) can run the REAL function against a recorder
    and see what it would write -- the roster check observes the
    staging, not a list the staging happens to share."""

    def __init__(self, dry=False):
        self.dry = dry
        self.written = []

    def ls(self, d):
        return [] if self.dry else [e.name for e in prodos.scandir(d)]

    def rm(self, path):
        if not self.dry:
            prodos.remove(path)

    def put(self, path, data):
        self.written.append(os.path.basename(path))
        if not self.dry:
            prodos.write(path, data, file_type=0x06, aux_type=0x0800,
                         overwrite=True)

    def read(self, path):
        return b'' if self.dry else read_tree(path)


def stage_bins(fs=None):
    """The PLAY_EXCLUDE programs, plus nas/ld/plasm, in /bin under the
    lower-case names the play image uses (a2til keeps case). Returns
    [(name, size)] and records every name written on `fs.written`."""
    fs = fs or _Fs()
    bindir = f'/mnt/{VOL}/BIN'
    shipped = []
    for name in EXTRA_BINS:
        data = fs.read(os.path.join(ROOT, 'build', f'{name}.bin'))
        fs.put(f'{bindir}/{name}', data)
        shipped.append((name, len(data)))
    # The composer wrote NAS and LD upper-case (the MAKEFILE names them
    # that way; ProDOS lookup is case-insensitive). Re-write them in
    # the same case as every other /bin entry so `ls /bin` is uniform.
    for name, path in zip(FULL_EXTRA_NAMES, (NAS_CUT, LD_BIN, PLASM_CUT)):
        if not fs.dry and not os.path.exists(path):
            raise SystemExit(f'build_full_image: missing {path}')
        for e in fs.ls(bindir):
            if e.upper() == name.upper():
                fs.rm(f'{bindir}/{e}')
        data = fs.read(path)
        fs.put(f'{bindir}/{name}', data)
        shipped.append((name, len(data)))
    return shipped


def planned_bin_names():
    """Every name /bin ends up holding, by RUNNING stage_bins() against a
    recorder: the play roster the replay carries (UTIL_NAMES) plus
    whatever stage_bins writes, case-folded."""
    fs = _Fs(dry=True)
    stage_bins(fs)
    return sorted({n.lower() for n in bpi.UTIL_NAMES} |
                  {n.lower() for n in fs.written})


def stage_inc():
    """The userland headers, under their own names so that
    `put /usr/inc/mm.procbank.equ` reads as it does in the tree.

    MAUX TEXT (high bit, $8D), the form `vi` writes and a person edits.
    Until KFIX10 these had to be ProDOS-standard text: nas split lines
    on $0D only and masked nothing, so a `put` of a high-bit header
    defined NO symbols and the undefined ones assembled as 0 without a
    diagnostic (measured 2026-10-19, docs/FULLDISK-NOTES.md sec 3). nas
    now reads either convention and refuses an undefined symbol
    (check-nas-text pins both), so the disk ships one convention."""
    shipped, excluded = user_inc_closure()
    mkdirs('/usr/inc')
    total = 0
    for fn in shipped:
        data = maux_text(read_tree(os.path.join(ROOT, 'inc', fn)))
        prodos.write(f'/usr/inc/{fn}', data, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        total += len(data)
    # PLASMA's runtime header, from src/plasma/inc/cmdsys.plh (held to
    # the PINNED PLASMA commit by check-plasma-examples D2; D4 reads this
    # staged file back from the image), byte for byte apart from the
    # text convention: `include "inc/cmdsys.plh"` in
    # Dave's own samplesrc/hello.pla finds it through fileio's
    # inc/ -> /usr/inc fallback (docs/PLASM-FIX-NOTES.md). Until
    # PLASM-FIX nothing staged it, so plasm compiled nothing here.
    data = maux_text(read_tree(PLASMA_CMDSYS_PLH))
    prodos.write('/usr/inc/cmdsys.plh', data, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    total += len(data)
    return shipped + ['cmdsys.plh'], excluded, total


#: What `plasma MODULE` needs on the volume to RUN a module plasm
#: compiled (docs/PLASMA-PORT.md): the seed hard-codes /mnt/MAUX/PLRT,
#: and rt's loader finds a module's dependencies in /mnt/MAUX/PLLIB/.
#: The cooked /bin/plasm needs neither -- this is for the program it
#: writes. Type $FE (REL), the loadable-module convention.
PLASMA_RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
PLASMA_LIBS = (('ARGS', 'args.mod'), ('FILEIO', 'fileio.mod'),
               ('LONGJMP', 'longjmp.mod'))


def stage_plasma():
    """/mnt/MAUX/PLRT and /mnt/MAUX/PLLIB/{ARGS,FILEIO,LONGJMP}: with
    /bin/plasma (staged since FULLDISK) they let `plasma hello.mod` run
    what `plasm hello.pla hello.mod` compiled (PLASM-FIX)."""
    prodos.write(f'/mnt/{VOL}/PLRT', read_tree(PLASMA_RT_MOD),
                 file_type=0xFE, aux_type=0x0000, overwrite=True)
    prodos.mkdir(f'/mnt/{VOL}/PLLIB')
    names = ['PLRT']
    for nm, fn in PLASMA_LIBS:
        prodos.write(f'/mnt/{VOL}/PLLIB/{nm}',
                     read_tree(os.path.join(ROOT, 'build', fn)),
                     file_type=0xFE, aux_type=0x0000, overwrite=True)
        names.append('PLLIB/' + nm)
    return names


def stage_examples():
    """examples/<dir>/<file> -> /usr/src/examples/<DIR>/<file>, the
    same bytes the site shows, converted to MAUX TEXT (high bit, $8D)
    like every file a person edits with `vi`. Until KFIX10 the sources
    had to be ProDOS-standard text (nas read only that) and the
    Makefiles maux text (make read only that); both tools now read
    either, so there is one convention and no exception by file name."""
    if not os.path.isdir(EXAMPLES_SRC):
        return []
    mkdirs('/usr/src/examples')
    staged = []
    for d in sorted(os.listdir(EXAMPLES_SRC)):
        dp = os.path.join(EXAMPLES_SRC, d)
        if not os.path.isdir(dp):
            continue
        prodos.mkdir(f'/usr/src/examples/{d.upper()}')
        for fn in sorted(os.listdir(dp)):
            raw = read_tree(os.path.join(dp, fn))
            data = maux_text(raw)
            prodos.write(f'/usr/src/examples/{d.upper()}/{fn}',
                         data, file_type=0x04, aux_type=0x0000,
                         overwrite=True)
            staged.append(f'{d.upper()}/{fn}')
    # L6: the same program cooked by plascut on the HOST, one spawnable
    # BIN beside the source (SITE.md L6; check-plasma-examples holds it
    # to a fresh cook of the pinned hello.pla).
    if 'HELLOPLA' in [x.split('/')[0] for x in staged]:
        prodos.write('/usr/src/examples/HELLOPLA/HELLO',
                     read_tree(HELLOPLA_CUT), file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        staged.append('HELLOPLA/HELLO')
    return staged


def stage_fixtures():
    """The real-world NuFX archives for nulib2 to unpack, with their
    PROVENANCE beside them (fixtures/PROVENANCE.md records the terms)."""
    out = []
    for sub, fn in FIXTURES:
        data = read_tree(os.path.join(ROOT, 'fixtures', sub, fn))
        prodos.write(f'/mnt/{VOL}/DEMO/{fn}', data, file_type=ARC_FTYPE,
                     aux_type=ARC_AUX, overwrite=True)
        out.append(fn)
    prov = maux_text(read_tree(os.path.join(ROOT, 'fixtures',
                                            'PROVENANCE.md')))
    prodos.write(f'/mnt/{VOL}/DEMO/PROVENANCE', prov, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    out.append('PROVENANCE')
    return out


# ---------------------------------------------------------------------
# /usr/lib/LIBA -- the one emulator step
# ---------------------------------------------------------------------
PUT_RE = re.compile(rb'^[ \t]+(?:put|use)[ \t]+(\S+)', re.I | re.M)


def staged_closure_hash(img, entries):
    """sha256 over every staged file a liba assembly reads: the source,
    its merged equ file, and the body files it puts, recursively --
    read from the staged image, so the key is the bytes nas will see.
    Also covers the cooked nas, which is the assembler."""
    h = hashlib.sha256()
    h.update(read_tree(NAS_CUT))
    seen = set()

    def visit(path):
        if path in seen:
            return
        seen.add(path)
        try:
            data = bytes(prodos.read(path))
        except Exception:  # noqa: BLE001 -- optional Q file
            return
        h.update(path.encode() + b'\0' + data)
        # staged files end lines with CR ($0D); `^` under re.M matches
        # after LF only, so the CRs are made LFs first -- without this
        # the pattern matched NOTHING and the key hashed only the top
        # files, never the body modules they put (found by E8's probe)
        text = bytes(b & 0x7F for b in data).replace(b'\r', b'\n')
        for m in PUT_RE.finditer(text):
            tgt = m.group(1).decode('latin-1')
            # The closure below follows ONLY absolute puts, and the
            # cache key is only as good as that. The composer writes
            # every put absolute (/usr/src/maux/...); if one ever is
            # not, a stale cache would be served silently -- so fail.
            if not tgt.startswith('/'):
                raise SystemExit(
                    f'build_full_image: {path} has a non-absolute put '
                    f'{tgt!r}; the LIBA cache key cannot follow it')
            visit(tgt + '.S' if not tgt.upper().endswith('.S') else tgt)

    vol = prodos.mount(img, readonly=True)
    try:
        for objp, srcp, kind in entries:
            visit(f'{bnl.LRDIR}/{srcp}')
            visit(f'{bnl.LRDIR}/{objp[:-1]}Q.S')
    finally:
        prodos.unmount(vol)
    return h.hexdigest()[:20]


def build_liba_objects(staged, entries):
    """Return [(name, bytes, type, aux)] in directory order for every
    liba REL assembly, from cache or from one emulator run."""
    key = staged_closure_hash(staged, entries)
    cdir = os.path.join(LIBA_CACHE, key)
    order_json = os.path.join(cdir, 'order.json')
    if os.path.exists(order_json) and not os.environ.get('FULL_LIBA_FRESH'):
        # order.json is the cache-hit marker and is written LAST and
        # atomically (below); a marker that does not parse, or names an
        # object that is not there, is a miss, not a wedge.
        try:
            order = json.load(open(order_json))
            hit = [(n, read_tree(os.path.join(cdir, n)), t, a)
                   for n, t, a in order]
            if len(hit) == len(entries):
                print(f'[build-full] LIBA objects: cache hit {key}')
                return hit
        except (OSError, ValueError):
            pass
        print(f'[build-full] LIBA objects: cache entry {key} unreadable; '
              f'rebuilding')
    why = ('forced by FULL_LIBA_FRESH' if os.environ.get('FULL_LIBA_FRESH')
           else 'cache miss')
    print(f'[build-full] LIBA objects: {why} {key}; booting '
          f'{len(entries)} nas assemblies')
    scratch = f'{staged}.liba'
    shutil.copyfile(staged, scratch)
    try:
        prodos.mount(scratch)
        try:
            lines = [f'cd {bnl.LRDIR}']
            for objp, srcp, _kind in entries:
                lines.append(f'nas -o /usr/lib/LIBA/{objp} {srcp} '
                             f'>> {bnl.LOG}')
            lines.append('echo SWEEPDONE')
            mkdirs('/usr/lib/LIBA')
            prodos.write(f'{bnl.LRDIR}/LIBASWEEP', bnl.sh_bytes(lines),
                         file_type=0x04, aux_type=0, overwrite=True)
        finally:
            prodos.unmount(VOL)
        import check_nas_librel as cnl
        steps = cnl.run_sweep(scratch, 'liba-objects',
                              script=f'{bnl.LRDIR}/LIBASWEEP',
                              max_steps=40000)
        if steps is None:
            raise SystemExit('build_full_image: the LIBA sweep failed')
        got = []
        prodos.mount(scratch, readonly=True)
        try:
            by = {e.name.upper(): e
                  for e in prodos.scandir('/usr/lib/LIBA')}
            log = b''
            try:
                log = bytes(b & 0x7F for b in prodos.read(
                    f'{bnl.LRDIR}/NASLOG'))
            except Exception:  # noqa: BLE001
                pass
            for objp, _srcp, _kind in entries:
                e = by.get(objp.upper())
                if e is None:
                    raise SystemExit(
                        f'build_full_image: nas never wrote LIBA/{objp}; '
                        f'NASLOG tail:\n'
                        f'{log.decode("latin-1")[-600:]}')
                if e.type != 0xF8:
                    raise SystemExit(f'LIBA/{objp} is type ${e.type:02X}, '
                                     f'not a $F8 REL object')
                got.append((objp, bytes(prodos.read(
                    f'/usr/lib/LIBA/{e.name}')), e.type, e.aux_type))
        finally:
            prodos.unmount(VOL)
    finally:
        if os.path.exists(scratch):
            os.remove(scratch)
    os.makedirs(cdir, exist_ok=True)
    for n, d, _t, _a in got:
        with open(os.path.join(cdir, n), 'wb') as f:
            f.write(d)
    tmp = f'{order_json}.tmp.{os.getpid()}'
    with open(tmp, 'w') as f:
        json.dump([[n, t, a] for n, _d, t, a in got], f)
    os.replace(tmp, order_json)             # the marker lands whole or not
    return got


def build(staged, mode='build'):
    """mode: 'build' (the image), 'check-pins' or 'repin-liba' (compose,
    boot nas fresh, compare with / rewrite pinned/liba, stop)."""
    print('[build-full] composing the native world (build_nas_librel_image'
          ', FULL layout)')
    bnl.configure_full(staged)
    rc = bnl.main()
    if rc:
        return rc

    print('[build-full] staging /bin, /usr/inc, examples, DEMO')
    prodos.mount(staged)
    try:
        bins = stage_bins()
        inc, inc_excl, inc_bytes = stage_inc()
        plm = stage_plasma()
        ex = stage_examples()
        fx = stage_fixtures()
        mkdirs('/usr/lib/LIBA')
    finally:
        prodos.unmount(VOL)

    entries = [e for e in bnl.LIBA_NAS if e[2] in ('lib', 'libpiece')]
    if mode != 'build':
        return liba_pins(staged, entries, mode)
    if pinned.current_tier() == 'build':
        # No emulator on this host by design: the pins ARE the objects,
        # verified against the lock before use (pinned.read_liba).
        objs = pinned.read_liba()
        print(f'[build-full] LIBA objects: {len(objs)} from pinned/liba '
              f'(MAUX_TIER=build, no emulator)')
        if len(objs) != len(entries) or \
                [o[0] for o in objs] != [e[0] for e in entries]:
            raise SystemExit(
                'build_full_image: pinned/liba does not list the objects '
                'the composer stages; re-pin with `make repin-liba` '
                '(needs the test tier)')
    else:
        objs = build_liba_objects(staged, entries)
    prodos.mount(staged)
    try:
        for name, data, ftype, aux in objs:
            prodos.write(f'/usr/lib/LIBA/{name}', data, file_type=ftype,
                         aux_type=aux, overwrite=True)
    finally:
        prodos.unmount(VOL)

    prodos_dates.normalize_image_dates(staged)

    vol = prodos.Volume(staged, readonly=True)
    try:
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()
    print(f'[build-full] /bin additions: '
          + ', '.join(f'{n} ({s} B)' for n, s in bins))
    print(f'[build-full] /usr/inc: {len(inc)} headers, {inc_bytes} B: '
          + ' '.join(inc))
    print('[build-full] kernel-private, NOT shipped: '
          + ' '.join(inc_excl))
    print(f'[build-full] PLASMA runtime for plasma MODULE: {plm}')
    print(f'[build-full] examples: {ex}')
    print(f'[build-full] DEMO fixtures: {fx}')
    print(f'[build-full] LIBA: {len(objs)} REL objects')
    print(f'[build-full] {OUT_IMG} ready ({os.path.getsize(staged)} bytes),'
          f' {free} of {total} blocks free')
    return 0


def liba_pins(staged, entries, mode):
    """Boot nas fresh (the cache is bypassed, so a stale cache entry
    cannot vouch for a stale pin) and compare with, or rewrite, pinned/."""
    os.environ['FULL_LIBA_FRESH'] = '1'
    fresh = build_liba_objects(staged, entries)
    if mode == 'repin-liba':
        pinned.write_liba(fresh)
        print(f'[build-full] re-pinned {len(fresh)} LIBA objects; commit '
              f'pinned/liba and dependencies.lock.json')
        return 0
    have = {n: (d, t, a) for n, d, t, a in pinned.read_liba()}
    bad = []
    for name, data, ftype, aux in fresh:
        pin = have.pop(name, None)
        if pin is None:
            bad.append(f'{name} is made by nas but has no pin')
        elif pin[0] != data:
            bad.append(f'{name}: nas made {len(data)} B, pinned/liba/'
                       f'{name}.rel is {len(pin[0])} B (different bytes)')
        elif pin[1:] != (ftype, aux):
            bad.append(f'{name}: type/aux ${ftype:02X}/{aux}, pinned '
                       f'${pin[1]:02X}/{pin[2]}')
    bad += [f'{n} is pinned but nas no longer makes it' for n in have]
    for b in bad:
        print(f'[check-liba-pins] FAIL: {b}', file=sys.stderr)
    if bad:
        print('[check-liba-pins] re-pin: make repin-liba   (rebuilds first; '
              'then commit pinned/liba and the lock)',
              file=sys.stderr)
        return 1
    print(f'[check-liba-pins] PASS: nas, booted fresh, made all '
          f'{len(fresh)} LIBA objects byte-identical to pinned/liba')
    return 0


def main():
    mode = 'build'
    for a in sys.argv[1:]:
        if a == '--check-pins':
            mode = 'check-pins'
        elif a == '--repin-liba':
            mode = 'repin-liba'
        else:
            print(f'usage: {sys.argv[0]} [--check-pins | --repin-liba]',
                  file=sys.stderr)
            return 2
    if mode != 'build':
        scratch = os.path.join(ROOT, 'build',
                               f'full-pincheck.po.tmp.{os.getpid()}')
        try:
            return build(scratch, mode)
        finally:
            if os.path.exists(scratch):
                os.remove(scratch)
    for path, label in ((bpi.OUT_IMG, 'play image (make play-image)'),
                        (NAS_CUT, 'nas.cut'), (LD_BIN, 'ld.bin')):
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    with imglock.publish(OUT_IMG) as staged:
        return build(staged)


if __name__ == '__main__':
    raise SystemExit(main())
