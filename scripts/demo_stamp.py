#!/usr/bin/env python3
"""demo_stamp.py -- what a demo film was recorded from, and whether it still is.

Stdlib only (check-site runs on hosts with no ffmpeg and no ffprobe).
Two jobs, both docs/RECORDER.md "Freshness stamps and film sizes":

  1. The recorder (scripts/demo_record.py) writes NAME.stamp.json (the
     UltraTerm's: NAME-ut.stamp.json) beside each film. It holds the
     sha256 of the demo script, the disk image it booted (and the slot-6
     floppy), EVERY source file the recorder process had loaded from the
     tree or from a2til, the verilogapple binaries and ROMs, the ffmpeg
     version line, the recording options (seed, --setup, host clock),
     and the sha256 of the film's own output files, so a stamp cannot be
     copied from one film to another.
  2. check-site (scripts/check_site.py, and `make site` through
     site/build.py) recomputes every one of those and names each stale
     film and which input changed; it reads the frame size out of the
     mp4 header (tkhd, coded size, pixel aspect, matrix), the webm's EBML
     header and each poster's PNG header, and requires the one size the
     recorder declares, on both displays.

Hashes, not mtimes: make 3.81 has whole-second mtimes and a copy resets
them, so an mtime says nothing about what a film shows.
"""
import hashlib
import json
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import demo_overlay                                          # noqa: E402
import demo_phos                                             # noqa: E402
import demo_ut                                               # noqa: E402

STAMP_VERSION = 2
UPSCALE = 2           # the encoder's scale=iw*UPSCALE (demo_record.Encoder)
DEFAULT_SEED = 1234   # the seed a published film is recorded with

# THE one place the output size is declared: the composed frame is
# demo_overlay.FRAME_W x FRAME_H on both displays, the encoder
# upscales it UPSCALE x (nearest), and the poster is the picture area
# alone, upscaled the same way.
FILM_SIZE = (demo_overlay.FRAME_W * UPSCALE, demo_overlay.FRAME_H * UPSCALE)
POSTER_SIZE = (demo_overlay.FRAME_W * UPSCALE, demo_overlay.PIC_H * UPSCALE)

BUILD = os.path.join(ROOT, 'build')
IMAGES = {'play': os.path.join(BUILD, 'play.po'),
          'full': os.path.join(BUILD, 'full.po'),
          'unpack': os.path.join(BUILD, 'demo-unpack.po'),
          'loop': os.path.join(BUILD, 'demo-loop.po'),
          'fed': os.path.join(BUILD, 'demo-fed.po'),
          'ddshrink': os.path.join(BUILD, 'demo-ddshrink.po')}
FLOPPIES = {'ddshrink': os.path.join(BUILD, 'demo-ddshrink-floppy.po')}

# The recorder sources every stamp must list at least (a stamp that
# lacks one was not written by this recorder). The stamp itself lists
# every file actually loaded; this is only the floor.
RECORDER_FILES = ('demo_record.py', 'demo_overlay.py', 'demo_png.py',
                  'demo_font.py', 'demo_ut.py', 'demo_phos.py',
                  'e2e_term.py', 'demo_stamp.py')

KINDS = ('mp4', 'webm', 'poster', 'vtt')
# The kinds that are one file PER PHOSPHOR (docs/DEMO-PHOSPHOR.md "The
# naming contract"); the other kind (the captions) is one per display,
# because the three films of a display are the same frames.
PHOSPHOR_KINDS = ('mp4', 'webm', 'poster')


def stamp_name(name, suffix=''):
    return '%s%s.stamp.json' % (name, suffix)


def out_name(kind, name, suffix='', phosphor=None):
    """ONE output file's name. The callers that want a single file by
    name -- the site builder, the release check, check-site's
    assertions -- would otherwise each re-spell the scheme, which is
    how a site ends up publishing a link the recorder never wrote."""
    if (kind in PHOSPHOR_KINDS) != bool(phosphor):
        raise ValueError('%s: %s' % (
            kind, 'needs a phosphor' if kind in PHOSPHOR_KINDS
            else 'takes no phosphor'))
    return out_names(name, suffix, (phosphor,) if phosphor else ())[
        (kind, phosphor)]


def out_names(name, suffix='', phosphors=None):
    """The files of one display, keyed (kind, phosphor): the phosphor is
    None for the kinds that have only one file per display. Every film
    names its monitor (NAME-ut-amber.mp4, poster-amber.png ...); there
    is no bare NAME.mp4."""
    phosphors = demo_phos.NAMES if phosphors is None else tuple(phosphors)
    out = {}
    for ph in phosphors:
        out['mp4', ph] = '%s%s-%s.mp4' % (name, suffix, ph)
        out['webm', ph] = '%s%s-%s.webm' % (name, suffix, ph)
        out['poster', ph] = 'poster%s-%s.png' % (suffix, ph)
    out['vtt', None] = '%s%s.vtt' % (name, suffix)
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


def settings(env=None):
    """Where the external tools are on THIS host, by the same variables
    and defaults as scripts/mcp_drive.py (check-recorder asserts they
    agree): the verilogapple checkout, its supervisor and ROM directory,
    and the a2til checkout."""
    env = os.environ if env is None else env
    va = os.path.expanduser(env.get('VERILOGAPPLE', '~/src/verilogapple'))
    sup = env.get('MAUX_SUPERVISOR',
                  os.path.join(va, 'sim/mcp/obj_dir/mcp_supervisor'))
    return {'verilogapple': va, 'supervisor': sup,
            'roms': env.get('VERILOGAPPLE_ROMS', os.path.join(va, 'sim/roms')),
            'a2til': os.path.expanduser(env.get('A2TIL', '~/src/a2til')),
            'smartport': env.get('VERILOGAPPLE_SMARTPORT_FW',
                                 os.path.join(va, 'sim/smartport/firmware')),
            'timemaster': env.get('VERILOGAPPLE_TIMEMASTER_FW',
                                  os.path.join(va, 'sim/timemaster/timemaster'))}


# External inputs are stamped by ROLE, never by absolute path, so the same
# stamp checks out on another host or user, or with the tools somewhere
# else: 'ext:supervisor', 'ext:worker_fast', 'ext:smartport',
# 'ext:timemaster', 'ext:rom/<rel to the ROM dir>', 'ext:a2til/<rel to the
# a2til checkout>'. Tree files stay relative to the repository.
def ext_path(key, env=None):
    st = settings(env)
    role = key[len('ext:'):]
    if role == 'supervisor':
        return st['supervisor']
    if role in ('worker_fast', 'worker_rtl'):
        return os.path.join(os.path.dirname(st['supervisor']),
                            {'worker_fast': 'mcp_worker_fast',
                             'worker_rtl': 'Vapple2e_sim_top'}[role])
    if role == 'smartport':
        return st['smartport']
    if role == 'timemaster':
        return st['timemaster']
    if role.startswith('rom/'):
        return os.path.join(st['roms'], role[4:])
    if role.startswith('a2til/'):
        return os.path.join(st['a2til'], role[6:])
    return os.path.join('/nonexistent-role', role)


# The UltraTerm revision the -ut films show: the firmware the worker is
# started with (demo_ut.mcp_env -> VERILOGAPPLE_ULTRATERM_FW) and the
# character ROM the host renderer draws with. Both come from the
# recorder's own pinned table, demo_ut.REVISIONS, for the revision it
# films (demo_ut.revision(): the original card, v1, unless MAUX_UT_REV
# says otherwise), never from a second copy of the names.
UT_REVISION = demo_ut.revision().name
UT_FIRMWARE = 'ultraterm/' + demo_ut.revision().firmware
UT_CHARGEN = 'ultraterm/' + demo_ut.revision().chargen


def machine_roles(backend, floppy=None, host_clock=False):
    """The external files the film's machine loads, DERIVED FROM THE
    RECORDER'S OWN CONFIG (the fast backend and the cards boot() resets
    in: the //e ROM and video ROM, the AppleMouse and SmartPort cards, a
    Disk ][ only with a floppy, the Timemaster only with --host-clock,
    the UltraTerm firmware and character ROM only for the card display).
    verilogapple cannot be asked what it loaded without editing it, so
    this list is the recorder's statement of the config; the worker may
    find some of these by its own search path (loaders.h), and the stamp
    assumes the VERILOGAPPLE_ROMS layout."""
    roles = ['ext:supervisor', 'ext:worker_fast', 'ext:rom/iie_cd_ef.rom',
             'ext:rom/iie_video.rom', 'ext:rom/applemouse.rom',
             'ext:smartport']
    if floppy:
        roles.append('ext:rom/disk2.rom')
    if host_clock:
        roles.append('ext:timemaster')
    if backend == 'ut':
        roles += ['ext:rom/' + UT_FIRMWARE, 'ext:rom/' + UT_CHARGEN]
    return roles


def key_of(path, root=ROOT, env=None):
    """A path as the stamp names it: relative to the tree when inside
    it, 'ext:a2til/<rel>' inside the a2til checkout, else absolute."""
    p = os.path.abspath(path)
    r = os.path.abspath(root)
    if p.startswith(r + os.sep):
        return os.path.relpath(p, r)
    a = os.path.abspath(settings(env)['a2til'])
    if p.startswith(a + os.sep):
        return 'ext:a2til/' + os.path.relpath(p, a)
    return p


def path_of(key, root=ROOT, env=None):
    if key.startswith('ext:'):
        return ext_path(key, env)
    return key if os.path.isabs(key) else os.path.join(root, key)


def _hash_or_none(p):
    return sha256_file(p) if p and os.path.isfile(p) else None


def loaded_files(script, root=ROOT):
    """Every .py file this process has loaded from the tree or from the
    a2til package: what the recorder is actually made of. Other demos'
    scripts (loaded earlier in the same process) and the fixtures are
    not inputs of THIS film."""
    out = set()
    skip = (os.path.join(root, 'site', 'demos') + os.sep,
            os.path.join(root, 'fixtures') + os.sep)
    script = os.path.abspath(script)
    for name, m in list(sys.modules.items()):
        f = getattr(m, '__file__', None)
        if not f or not f.endswith('.py'):
            continue
        f = os.path.abspath(f)
        mine = f.startswith(os.path.abspath(root) + os.sep)
        if not (mine or name.split('.')[0] == 'a2til'):
            continue
        if f.startswith(skip) and f != script:
            continue
        if os.path.isfile(f):
            out.add(f)
    return out


def ffmpeg_version(ffmpeg='ffmpeg'):
    """First line of `ffmpeg -version`, or None if there is no ffmpeg."""
    try:
        r = subprocess.run([ffmpeg, '-version'], capture_output=True,
                           text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return (r.stdout.splitlines() or [None])[0] if r.returncode == 0 else None


def snapshot(script, image=None, floppy=None, backend='text80',
             seed=DEFAULT_SEED, setup=(), host_clock=False, ffmpeg=None,
             extra_files=(), root=ROOT, env=None):
    """What a film is a function of, as hashes, taken BEFORE the machine
    boots so an edit during a long recording cannot be stamped as fresh
    (finish() rehashes and refuses)."""
    keys = {key_of(os.path.join(HERE, fn), root, env)
            for fn in RECORDER_FILES}
    keys |= {key_of(f, root, env) for f in loaded_files(script, root)}
    keys |= {key_of(f, root, env) for f in extra_files}
    for role in machine_roles(backend, floppy, host_clock):
        if os.path.isfile(ext_path(role, env)):
            keys.add(role)
    return {'script': sha256_file(script),
            'image': _hash_or_none(image),
            'floppy': _hash_or_none(floppy) if floppy else None,
            'files': {k: sha256_file(path_of(k, root, env))
                      for k in sorted(keys)},
            'seed': seed, 'setup': list(setup),
            'host_clock': bool(host_clock), 'ffmpeg': ffmpeg,
            'ut_revision': UT_REVISION if backend == 'ut' else None,
            '_paths': {'script': os.path.abspath(script), 'image': image,
                       'floppy': floppy, 'root': root, 'env': env}}


def finish(snap):
    """At the end of a recording: add the modules loaded since (hashed
    now), and return the names of anything that changed on disk while
    the recording ran (the recording must then be refused)."""
    p = snap['_paths']
    root, env = p['root'], p['env']
    changed = []
    if sha256_file(p['script']) != snap['script']:
        changed.append(key_of(p['script'], root, env))
    for key, sha in snap['files'].items():
        f = path_of(key, root, env)
        if not os.path.isfile(f) or sha256_file(f) != sha:
            changed.append(key)
    for k in ('image', 'floppy'):
        if p[k] and snap[k] and _hash_or_none(p[k]) != snap[k]:
            changed.append(key_of(p[k], root, env))
    for f in loaded_files(p['script'], root):
        k = key_of(f, root, env)
        if k not in snap['files']:
            snap['files'][k] = sha256_file(f)
    return changed


def write_stamp(dest, name, suffix, backend, snap, measures=None):
    """Write NAME[-ut].stamp.json into dest, binding it to the output
    files already in dest (call after the encoder has closed and the
    sidecars are written)."""
    inputs = {k: v for k, v in snap.items() if not k.startswith('_')}
    outputs = {}
    for fn in out_names(name, suffix).values():
        p = os.path.join(dest, fn)
        if os.path.isfile(p):
            outputs[fn] = sha256_file(p)
    doc = {'version': STAMP_VERSION, 'name': name, 'backend': backend,
           'film_size': list(FILM_SIZE), 'poster_size': list(POSTER_SIZE),
           'inputs': inputs, 'outputs': outputs}
    if measures:
        # figures the run measured (t.measure): not an input, not checked
        # for freshness; pages quote them (docs/RECORDER.md)
        doc['measures'] = dict(measures)
    path = os.path.join(dest, stamp_name(name, suffix))
    with open(path, 'w') as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write('\n')
    return path


def inputs_now(stamp, script, image=None, floppy=None, root=ROOT, env=None):
    """The current hashes of everything the stamp lists."""
    old = stamp.get('inputs') or {}
    files = {}
    for key in (old.get('files') or {}):
        files[key] = _hash_or_none(path_of(key, root, env))
    return {'script': sha256_file(script), 'image': _hash_or_none(image),
            'floppy': _hash_or_none(floppy) if floppy else None,
            'files': files,
            'ut_revision': (UT_REVISION if stamp.get('backend') == 'ut'
                            else None)}


def stale_reasons(stamp, now):
    """Why a stamp no longer matches `now` (inputs_now), as strings."""
    out = []
    old = stamp.get('inputs')
    if stamp.get('version') != STAMP_VERSION or not isinstance(old, dict):
        return ['the stamp is not a version-%d stamp' % STAMP_VERSION]
    for key, what in (('script', 'the demo script'),
                      ('image', 'the disk image it booted'),
                      ('floppy', 'the slot-6 floppy')):
        if key == 'floppy' and old.get(key) is None and now.get(key) is None:
            continue
        if now.get(key) is None:
            out.append('%s is absent here, so the film cannot be checked'
                       % what)
        elif old.get(key) != now[key]:
            out.append('%s changed since the film was recorded' % what)
    if 'ut_revision' in now and old.get('ut_revision') != now['ut_revision']:
        out.append('the film shows UltraTerm revision %r, the recorder now '
                   'films %r' % (old.get('ut_revision'), now['ut_revision']))
    files = old.get('files') or {}
    for fn in RECORDER_FILES:
        if 'scripts/' + fn not in files:
            out.append('the stamp does not list recorder source '
                       'scripts/%s' % fn)
    # the floor for the machine: a stamp is only checked against the files
    # it lists, so one edited to drop a ROM entry would never go stale when
    # that ROM changed. Every ROM the film's own config loads must be
    # listed (the UltraTerm firmware and character ROM for a -ut film).
    for role in machine_roles(stamp.get('backend'), old.get('floppy'),
                              old.get('host_clock')):
        if role.startswith('ext:rom/') and role not in files:
            out.append('the stamp does not list machine ROM %s'
                       % role[len('ext:rom/'):])
    for key, sha in sorted(files.items()):
        cur = now['files'].get(key)
        if cur is None:
            out.append('input %s is gone or unreadable' % key)
        elif cur != sha:
            out.append('input %s changed since the film was recorded' % key)
    return out


def demo_constants(script_path, *names):
    """Module-level literal constants of a demo script, by name, read
    with ast (the script is hashed into the stamp, so unlike the stamp
    itself it cannot be edited after the film without going stale)."""
    import ast
    out = {}
    try:
        with open(script_path) as f:
            tree = ast.parse(f.read())
    except (OSError, SyntaxError):
        return out
    for n in tree.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and \
                isinstance(n.targets[0], ast.Name) and \
                n.targets[0].id in names:
            try:
                out[n.targets[0].id] = ast.literal_eval(n.value)
            except ValueError:
                pass
    return out


def measure_reasons(stamp, vtt_path, script_path):
    """A stamp's "measures" (t.measure in the demo) have no hash of their
    own, so each is held to the captions, which the stamp DOES bind, and
    to the demo script, which it also binds. The script declares
    MEASURE_CAPTIONS = {measure: the words a caption puts right before the
    figure}; the film's .vtt must hold a cue with those words followed by
    the figure as "%.2f million". A figure that only some OTHER caption
    states, or two figures swapped, is therefore an error. The script may
    also declare MEASURE_ORDER = [(a, b), ...]: the measure a must be
    smaller than b (the story the film tells, and the gate asserts)."""
    out = []
    ms = stamp.get('measures') or {}
    if not ms:
        return out
    c = demo_constants(script_path, 'MEASURE_CAPTIONS', 'MEASURE_ORDER')
    anchors = c.get('MEASURE_CAPTIONS') or {}
    try:
        with open(vtt_path, errors='replace') as f:
            text = f.read()
    except OSError:
        return out                      # the missing file is reported
    for k, v in sorted(ms.items()):
        if k not in anchors:
            out.append('measure %s has no MEASURE_CAPTIONS entry in the '
                       'demo script, so no caption vouches for it' % k)
            continue
        want = '%s %.2f million' % (anchors[k], v / 1e6)
        if want not in text:
            out.append('measure %s=%s is not the figure its caption states '
                       '(no cue says %r): the stamp and the film disagree'
                       % (k, v, want))
    for a, b in c.get('MEASURE_ORDER') or ():
        if a in ms and b in ms and not ms[a] < ms[b]:
            out.append('measures %s=%s and %s=%s are out of order (%s must '
                       'be smaller)' % (a, ms[a], b, ms[b], a))
    return out


def option_reasons(stamp):
    """A published film is recorded with the default seed, no --setup
    and the pinned clock; anything else is a measurement, not a film."""
    old = stamp.get('inputs') or {}
    out = []
    if old.get('setup') != []:
        out.append('recorded with --setup %r' % (old.get('setup'),))
    if old.get('host_clock') is not False:
        out.append('recorded with --host-clock')
    if old.get('seed') != DEFAULT_SEED:
        out.append('recorded with seed %r, not %d' % (old.get('seed'),
                                                      DEFAULT_SEED))
    return out


# -- sizes, read from the file headers -------------------------------------

def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
        raise ValueError('not a PNG')
    return struct.unpack('>II', head[16:24])


def _boxes(buf, start, end):
    """(type, body_start, body_end) of each ISO-BMFF box in buf[start:end]."""
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack('>I4s', buf[pos:pos + 8])
        hdr = 8
        if size == 1:
            size = struct.unpack('>Q', buf[pos + 8:pos + 16])[0]
            hdr = 16
        elif size == 0:
            size = end - pos
        if size < hdr or pos + size > end:
            raise ValueError('bad box %r at %d' % (typ, pos))
        yield typ, pos + hdr, pos + size
        pos += size


def _find(buf, start, end, path):
    """Body span of the first box at the nested type path, or None."""
    for typ, a, b in _boxes(buf, start, end):
        if typ == path[0]:
            if len(path) == 1:
                return a, b
            got = _find(buf, a, b, path[1:])
            if got:
                return got
    return None


IDENTITY = (0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def mp4_info(path):
    """The first video track's display size (tkhd), coded size (the
    avc1 sample entry), pixel aspect (pasp, default 1:1) and whether
    its display matrix is the identity. No ffprobe: the house tree does
    not require it."""
    total = os.path.getsize(path)
    with open(path, 'rb') as f:
        pos = 0
        while pos + 8 <= total:
            f.seek(pos)
            hd = f.read(16)
            size, typ = struct.unpack('>I4s', hd[:8])
            hdr = 8
            if size == 1:
                size = struct.unpack('>Q', hd[8:16])[0]
                hdr = 16
            elif size == 0:
                size = total - pos
            if size < hdr:
                raise ValueError('bad top-level box at %d' % pos)
            if typ == b'moov':
                f.seek(pos + hdr)
                moov = f.read(size - hdr)
                return _moov_info(moov)
            pos += size
    raise ValueError('no moov box (not an mp4)')


def _moov_info(moov):
    for t1, a1, b1 in _boxes(moov, 0, len(moov)):
        if t1 != b'trak':
            continue
        tk = _find(moov, a1, b1, [b'tkhd'])
        if not tk:
            continue
        w, h = struct.unpack('>II', moov[tk[1] - 8:tk[1]])
        if not (w >> 16 and h >> 16):
            continue                     # an audio track
        matrix = struct.unpack('>9i', moov[tk[1] - 44:tk[1] - 8])
        info = {'size': (w >> 16, h >> 16),
                'identity': tuple(matrix) == IDENTITY,
                'coded': None, 'sar': (1, 1)}
        stsd = _find(moov, a1, b1, [b'mdia', b'minf', b'stbl', b'stsd'])
        if stsd:
            ent = stsd[0] + 8            # version/flags + entry_count
            esz, = struct.unpack('>I', moov[ent:ent + 4])
            body = ent + 8
            if esz >= 8 + 78:
                info['coded'] = struct.unpack('>HH',
                                              moov[body + 24:body + 28])
                for t, a, b in _boxes(moov, body + 78, ent + esz):
                    if t == b'pasp' and b - a >= 8:
                        info['sar'] = struct.unpack('>II', moov[a:a + 8])
        return info
    raise ValueError('no video track in moov')


def mp4_size(path):
    return mp4_info(path)['size']


# EBML: just enough to find Segment > Tracks > TrackEntry > Video >
# PixelWidth / PixelHeight in the first 256 KB of a webm.
_EBML_MASTERS = {0x18538067, 0x1654AE6B, 0xAE, 0xE0}


def _vint(buf, pos, keep_marker):
    b = buf[pos]
    n = 1
    while n <= 8 and not b & (0x80 >> (n - 1)):
        n += 1
    if n > 8:
        raise ValueError('bad EBML vint')
    v = b if keep_marker else b & (0xFF >> n)
    for i in range(1, n):
        v = v << 8 | buf[pos + i]
    unknown = (not keep_marker) and v == (1 << (7 * n)) - 1
    return v, n, unknown


def webm_size(path):
    with open(path, 'rb') as f:
        buf = f.read(1 << 18)
    found = {}

    def walk(pos, end):
        while pos < end and not ({0xB0, 0xBA} <= set(found)):
            eid, n, _ = _vint(buf, pos, True)
            size, m, unk = _vint(buf, pos + n, False)
            body = pos + n + m
            stop = min(end if unk else body + size, len(buf))
            if eid in _EBML_MASTERS:
                walk(body, stop)
            elif eid in (0xB0, 0xBA):
                found[eid] = int.from_bytes(buf[body:stop], 'big')
            pos = stop

    try:
        walk(0, len(buf))
    except (IndexError, ValueError):
        pass
    if 0xB0 not in found or 0xBA not in found:
        raise ValueError('no PixelWidth/PixelHeight in the first 256 KB '
                         '(not a webm)')
    return (found[0xB0], found[0xBA])


# -- the check-site side ----------------------------------------------------

def film_errors(demos_dir, demos, ut_on, root=ROOT, images=None,
                floppies=None, ffmpeg_now='probe', env=None):
    """Errors for every film the build would publish from demos_dir.
    demos maps name -> {'backends', 'image', 'floppy', 'path'}. With no
    film file at all the build is a film-less one and nothing is
    checked; with any, every demo must have its films."""
    errs = []
    images = IMAGES if images is None else images
    floppies = FLOPPIES if floppies is None else floppies
    dirs = {n: os.path.join(demos_dir, n) for n in demos}

    def there(name, suffix):
        return {k: os.path.isfile(os.path.join(dirs[name], fn))
                for k, fn in out_names(name, suffix).items()}

    present = any(any(there(n, '').values()) for n in demos)
    if not present:
        return errs
    if ffmpeg_now == 'probe':
        ffmpeg_now = ffmpeg_version()
    sizes = {}          # (kind, size) -> [label]

    def note(kind, size, label):
        sizes.setdefault((kind, tuple(size)), []).append(label)

    for name, d in sorted(demos.items()):
        for suffix, on in (('', True),
                           ('-ut', ut_on and 'ut' in d['backends'])):
            if not on:
                continue
            have = there(name, suffix)
            names = out_names(name, suffix)
            miss = [k for k, v in have.items() if not v]
            if not suffix and miss and (not ut_on or
                                        len(miss) == len(have)):
                errs.append('demos/%s: no %s -- every demo the site '
                            'publishes needs its film files; record with '
                            '`make demos`' % (
                                name, ', '.join(names[k] for k in miss)))
            if not any(have.values()):
                continue
            label = 'demos/%s/%s' % (name, names['mp4', demo_phos.DEFAULT])
            wd = dirs[name]
            exp = {'mp4': FILM_SIZE, 'webm': FILM_SIZE,
                   'poster': POSTER_SIZE}
            readers = {'mp4': None, 'webm': webm_size, 'poster': png_size}
            # EVERY variant is read and held to the size on its own: one
            # check standing for the three phosphors would let a
            # mis-sized amber film through behind a good paper one
            for (kind, ph), fn in names.items():
                if kind not in readers or not have[kind, ph]:
                    continue
                reader = readers[kind]
                p = os.path.join(wd, fn)
                lab = 'demos/%s/%s' % (name, fn)
                try:
                    if kind == 'mp4':
                        info = mp4_info(p)
                        got = info['size']
                    else:
                        got = reader(p)
                except (ValueError, OSError, struct.error) as e:
                    errs.append('%s: cannot read the frame size (%s)'
                                % (lab, e))
                    continue
                note('poster' if kind == 'poster' else 'film', got, lab)
                if tuple(got) != exp[kind]:
                    what = 'size' if kind == 'poster' else 'frame size'
                    errs.append('%s: %s %dx%d, the recorder declares %dx%d '
                                '(re-record with `make demos`)'
                                % ((lab, what, got[0], got[1]) + exp[kind]))
                if kind == 'mp4':
                    if info['coded'] and tuple(info['coded']) != FILM_SIZE:
                        errs.append('%s: coded size %dx%d, not the declared '
                                    '%dx%d' % ((lab,) + tuple(info['coded'])
                                               + FILM_SIZE))
                    if tuple(info['sar']) != (1, 1):
                        errs.append('%s: pixel aspect %d:%d, not 1:1 (the '
                                    'player would stretch it)'
                                    % ((lab,) + tuple(info['sar'])))
                    if not info['identity']:
                        errs.append('%s: display matrix is not the identity '
                                    '(a rotated or flipped film)' % lab)
            spath = os.path.join(wd, stamp_name(name, suffix))
            if not os.path.isfile(spath):
                errs.append('%s: no %s -- the film predates the freshness '
                            'stamp; re-record with `make demos`'
                            % (label, stamp_name(name, suffix)))
                continue
            try:
                with open(spath) as f:
                    stamp = json.load(f)
                assert isinstance(stamp, dict)
            except (ValueError, OSError, AssertionError) as e:
                errs.append('%s: unreadable stamp (%s); re-record with '
                            '`make demos`' % (label, e))
                continue
            errs += _stamp_errors(label, name, suffix, stamp, wd, names, d,
                                  root, images, floppies, ffmpeg_now, env)
    for kind in ('film', 'poster'):
        seen = {s: l for (k, s), l in sizes.items() if k == kind}
        if len(seen) > 1:
            errs.append('the %ss are not one size: %s' % (kind, '; '.join(
                '%dx%d: %s' % (s[0], s[1], ', '.join(l[:3]) +
                               (' ...' if len(l) > 3 else ''))
                for s, l in sorted(seen.items()))))
    return errs


def _stamp_errors(label, name, suffix, stamp, wd, names, d, root, images,
                  floppies, ffmpeg_now, env=None):
    errs = []
    redo = '; re-record with `make demos`'
    if stamp.get('name') != name:
        errs.append('%s: its stamp is for demo %r%s'
                    % (label, stamp.get('name'), redo))
    if (stamp.get('backend') == 'ut') != bool(suffix):
        errs.append('%s: its stamp is for the %r display%s'
                    % (label, stamp.get('backend'), redo))
    if stamp.get('version') != STAMP_VERSION:
        errs.append('%s: a version-%r stamp, this checker reads version %d%s'
                    % (label, stamp.get('version'), STAMP_VERSION, redo))
        return errs
    outs = stamp.get('outputs') or {}
    for fn in names.values():           # every phosphor's file, each bound
        p = os.path.join(wd, fn)
        if fn not in outs:
            errs.append('%s: the stamp binds no %s%s' % (label, fn, redo))
        elif not os.path.isfile(p):
            errs.append('%s: the stamp binds %s but the file is absent%s'
                        % (label, fn, redo))
        elif sha256_file(p) != outs[fn]:
            errs.append('%s: %s is not the file this stamp was written '
                        'for%s' % (label, fn, redo))
    for why in option_reasons(stamp):
        errs.append('%s: %s%s' % (label, why, redo))
    for why in measure_reasons(stamp, os.path.join(wd, names['vtt', None]),
                             d['path']):
        errs.append('%s: %s%s' % (label, why, redo))
    img = images.get(d.get('image') or 'play')
    flop = floppies.get(d['floppy']) if d.get('floppy') else None
    if not (img and os.path.isfile(img)):
        errs.append('%s: the disk image %s is absent, so the film cannot '
                    'be checked (make play-image / demo images)'
                    % (label, key_of(img, root) if img else d.get('image')))
        img = None
    if flop and not os.path.isfile(flop):
        errs.append('%s: the floppy %s is absent, so the film cannot be '
                    'checked' % (label, key_of(flop, root)))
        flop = None
    try:
        now = inputs_now(stamp, d['path'], img, flop, root, env)
    except OSError as e:
        errs.append('%s: cannot hash its inputs (%s)' % (label, e))
        return errs
    if img is None:
        now['image'] = stamp['inputs'].get('image')    # already reported
    if d.get('floppy') and flop is None:
        now['floppy'] = stamp['inputs'].get('floppy')
    for why in stale_reasons(stamp, now):
        errs.append('%s: stale -- %s%s' % (label, why, redo))
    want = (stamp.get('inputs') or {}).get('ffmpeg')
    if want:
        if ffmpeg_now is None:
            errs.append('%s: ffmpeg is not on PATH, so the encoder version '
                        'it was recorded with cannot be checked' % label)
        elif ffmpeg_now != want:
            errs.append('%s: stale -- ffmpeg is now %r, it was recorded '
                        'with %r%s' % (label, ffmpeg_now, want, redo))
    return errs
