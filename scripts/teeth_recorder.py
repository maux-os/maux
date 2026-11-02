#!/usr/bin/env python3
"""teeth_recorder.py -- the sabotage runner behind check-recorder's teeth
(docs/RECORDER-NOTES.md sec 4 and 11), on scripts/teeth_lib.py (HYG-4).
NOT a gate and in no sweep: it breaks the recorder's real source one way
at a time, runs the whole of scripts/check_recorder.py (about 50 s each)
and requires the INTENDED row RED (by its full label: a row either
failed or it did not); a sabotage that also reddens other rows is
printed as collateral, not hidden. It restores from the captured bytes
(never `git checkout`, which would destroy an uncommitted edit of the
recorder). The GUEST teeth break the demo's SUBJECT instead of the
recorder: they run fixtures/demos/mygrep.py through the CLI with --setup
commands typed at the shell on the gate's own copy-on-write image and
require the intended failure label on the CLI's own FAIL line. Exit
status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2 runner
broken).

  python3 scripts/teeth_recorder.py              # all
  python3 scripts/teeth_recorder.py clock badge  # by name prefix
  python3 scripts/teeth_recorder.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

PNG = 'scripts/demo_png.py'
REC = 'scripts/demo_record.py'
OVL = 'scripts/demo_overlay.py'
PHOS = 'scripts/demo_phos.py'
STAMP = 'scripts/demo_stamp.py'

# (name, [(file, old, new), ...], substring of the row that must go red)
SOURCE = [
    ('paeth-always-a', [(PNG, "def _paeth(a, b, c):\n    p = a + b - c",
                         "def _paeth(a, b, c):\n    return a\n    p = a + b - c")],
     'round-trips all five'),
    ('sub-off-by-one', [(PNG, "out[i] = (out[i] + out[i - BPP]) & 255",
                         "out[i] = (out[i] + out[i - BPP - 1]) & 255")],
     'round-trips all five'),
    ('avg-wrong-shift', [(PNG, "((left + prev[i]) >> 1)", "((left + prev[i]) >> 2)")],
     'round-trips all five'),
    ('up-ignores-prev', [(PNG, "return bytearray((c + p) & 255 for c, p in zip(cur, prev))",
                          "return bytearray(cur)")],
     'round-trips all five'),
    ('png-accepts-bad-methods', [(PNG, "            if comp != 0 or filt != 0:", "            if False:")],
     'PNG decoder refuses what it must'),
    ('png-iend-optional', [(PNG, "    raise ValueError('PNG has no IEND chunk (truncated)')", "    return")],
     'PNG decoder refuses what it must'),
    ('png-struct-error-on-cut', [(PNG, "        if pos + 12 > len(data):", "        if False:")],
     'PNG decoder refuses what it must'),
    ('png-crc-unchecked', [(PNG, "        if zlib.crc32(kind + body) != crc:", "        if False:")],
     'PNG decoder refuses what it must'),
    ('seed-ignored', [(REC, "n = self.rng.randint(*KEY_FRAMES)", "n = 4")],
     'another seed'),
    ('fast-keeps-all', [(REC, "if self.fast_phase % self.fast_n:\n                return",
                         "if False:\n                return")],
     'fast(16)'),
    ('strip-never-live', [(OVL, "live = [t for t in self.tokens if frame - t[2] < KEY_LINGER]",
                           "live = []")],
     'key strip'),
    ('abort-leaves-files', [(REC, "res.ok, res.error = False, e\n    finally:",
                             "res.ok, res.error = False, e\n        if record:\n            rec.write_sidecars(work, demo['name'])\n            publish(work, record, demo['name'])\n    finally:")],
     'aborts the recording'),
    ('extra-cycles-per-frame', [(REC, "r = self.c.call_tool('step', {'cycles': FRAME_CYCLES})",
                                 "r = self.c.call_tool('step', {'cycles': FRAME_CYCLES + 20000})")],
     'every step is one'),
    ('hash-nondeterministic', [(REC, "hashlib.sha256(frame).hexdigest()",
                                "hashlib.sha256(frame + os.urandom(1)).hexdigest()")],
     'one seed twice'),
    ('strip-over-picture', [(REC, "frame = pic + strip",
                             "frame = pic[:-len(strip)] + strip + bytes(len(strip))")],
     'overlay: the picture'),
    ('cap-in-picture-while-key-live', [(REC, "frame = pic + strip",
                                        "frame = (pic if not caps else pic[:73710] + b'\\xff' * 30 + pic[73740:]) + strip")],
     'overlay: the picture'),
    ('expect-never-raises', [(REC, "elif rows != [s.rstrip() for s in spec]:", "elif False:")],
     'aborts the recording'),
    ('expect-membership-only', [(REC, "elif rows != [s.rstrip() for s in spec]:",
                                 "elif any(r not in [s.rstrip() for s in spec] for r in rows):")],
     'drops one line'),
    ('clock-unpinned', [(REC, "PINNED_CLOCK = {'clock': False}", "PINNED_CLOCK = {}")],
     'clock pinned'),
    ('badge-width-constant', [(OVL, "    return FRAME_W - MARGIN - badge_width(badge) - CAP_GAP",
                               "    return FRAME_W - 2 * MARGIN - 214")],
     'badge never overlaps'),
    ('highbit-silent-question-mark', [(OVL, "    if ord(ch) > 126:", "    if False:")],
     'high-bit key'),
    ('abort-does-not-kill', [(REC, "        self.proc.kill()\n        try:", "        try:")],
     'abort with the encoder running'),
    ('abort-keeps-workdir', [(REC, "        if work:\n            shutil.rmtree(work, ignore_errors=True)", "        if work:\n            pass")],
     'abort with the encoder running'),
    ('no-poster-fallback', [(REC, "        if not self.poster_pngs and self._pic is not None:", "        if False:")],
     'encoder (fake ffmpeg)'),
    ('hold-zero-steps-one', [(REC, "for _ in range(round(seconds * FPS)):    # hold(0) steps nothing", "for _ in range(max(1, round(seconds * FPS))):    # hold(0) steps nothing")],
     'hold(0)'),
    ('disk-not-restored', [(REC, "        e2e_term.DISK = old_disk\n    return res", "    return res")],
     'hold(0)'),
    ('cli-stops-at-first-exception', [(REC, "{e}', file=sys.stderr)\n                continue", "{e}', file=sys.stderr)\n                return 1")],
     'one demo raising'),
    ('ffmpeg-not-checked', [(REC, "    if args.record and not args.no_encode:\n        bad = ffmpeg_problems()", "    if False:\n        bad = ffmpeg_problems()")],
     'ffmpeg missing'),
    # the phosphor (docs/DEMO-PHOSPHOR.md)
    ('tint-cache-never-refreshes', [(REC, "if self._tint_src is not self._pic:", "if self._tint_src is None:")],
     'a still screen'),
    ('strip-tinted', [(REC, "enc.write(pics[ph] + strip)", "enc.write(pics[ph] + demo_phos.tint(strip, demo_phos.ALL_TABLES[ph]))")],
     'fed its own tint'),
    ('belongs-keeps-phosphor', [(REC, "        if stem.endswith('-' + ph):", "        if False:")],
     'display is read AFTER'),
    ('stamp-one-size-for-three', [(STAMP, "if kind not in readers or not have[kind, ph]:", "if kind not in readers or not have[kind, ph] or ph not in (None, demo_phos.DEFAULT):")],
     'EVERY variant'),
    ('canon-accepts-third-grey', [(PHOS, "    if bad:\n        raise PhosError(", "    if False:\n        raise PhosError(")],
     'third grey'),
    ('bright-maps-to-normal', [(PHOS, "t[BRIGHT[ch]] = highlight[ch]", "t[BRIGHT[ch]] = normal[ch]")],
     'injective'),
]

CAT = ['cp /bin/cat /bin/%s']
DROP = ['cp /bin/grep /bin/grep.real', 'rm /bin/grep',
        "echo '#!/bin/sh' > /bin/grep",
        "echo '/bin/grep.real $1 $2 | sed 1d' >> /bin/grep"]
# (name, --setup commands, label the failure must name)
GUEST = [
    ('guest-grep-is-cat', [CAT[0] % 'grep'], 'grep prints the same rows'),
    ('guest-cmp-is-cat', [CAT[0] % 'cmp'], 'cmp says nothing'),
    ('guest-grep-drops-a-line', DROP, 'grep prints the same rows'),
]


#: the FULL row label each `want` above stands for (the gate's own text)
LABEL = {
    'round-trips all five':
        'PNG decoder round-trips all five row filters',
    'PNG decoder refuses what it must':
        'PNG decoder refuses what it must (CRC, IHDR, truncation, IEND) and accepts a split IDAT',
    'another seed':
        'TEETH: another seed gives a different hash sequence',
    'fast(16)':
        'fast(16): badge, and cycles rise 16 frames per kept frame',
    'key strip':
        'key strip: pixels on a frame exactly when a key is live',
    'aborts the recording':
        'a wrong expect_text aborts the recording, nothing left behind',
    'every step is one':
        'every step is one 34,016-cycle frame: frames == duration x 30',
    'one seed twice':
        'one seed twice: identical frame-hash sequences',
    'overlay: the picture':
        'overlay: the picture is the emulator pixels on EVERY frame, the strip below it',
    'drops one line':
        'TEETH: a grep that drops one line turns mygrep red',
    'clock pinned':
        'clock pinned: a demo reads no host time, and records the same twice',
    'badge never overlaps':
        'overlay: the badge never overlaps the key caps (x100, x1000, 1e9)',
    'high-bit key':
        'overlay: a high-bit key draws a marker, not a silent ?',
    'abort with the encoder running':
        'abort with the encoder running: killed, its directory gone, OUTDIR empty',
    'encoder (fake ffmpeg)':
        'encoder (fake ffmpeg): one encoder per phosphor, each reading exactly frames x 720x420x3 bytes, outputs published',
    'hold(0)':
        'hold(0) steps no frame; run_demo restores e2e_term.DISK',
    'one demo raising':
        'one demo raising does not hide the next (the CLI goes on)',
    'a still screen':
        'phosphor: a still screen reuses its tint, a changed screen gets its own, and no stale tint is ever served',
    'fed its own tint':
        "encoder (fake ffmpeg): each phosphor's encoder is fed its own tint of the picture and the UNtinted strip, frame for frame",
    'display is read AFTER':
        "phosphor: a file's display is read AFTER its phosphor is taken off (poster-ut-amber is the card's); a demo named like a display or a phosphor is refused",
    'EVERY variant':
        'stamp: out_names is keyed (kind, phosphor), every film names its monitor, and EVERY variant gets its own size check',
    'third grey':
        'phosphor: a //e picture with a third grey is a RecorderError naming the demo, never a black frame',
    'injective':
        "phosphor: every phosphor's tables keep the three levels three colours (injective), black stays black, the pairs differ",
    'ffmpeg missing':
        'ffmpeg missing: --record names it, builds nothing',
}
GATE = 'python3 scripts/check_recorder.py'
CLI = ('python3', 'scripts/demo_record.py', 'fixtures/demos/mygrep.py',
       '--backend', 'text80')


def source_tooth(name, edits, want):
    return T.Tooth(name, edits=edits, witness=T.SourceOnly(), checks=[
        T.Check(GATE, 'recorder', T.Rows(red=[LABEL[want]]))])


def guest_tooth(name, setup, label):
    argv = CLI
    for c in setup:
        argv = argv + ('--setup', c)
    return T.Tooth(name, witness=T.CommandMutation(
        'the mutation is the --setup commands typed into the guest by '
        'demo_record.py; the FAIL line naming the label it breaks at is '
        'its only evidence (the gate\'s own TEETH rows do the same)'),
        checks=[T.Check(T.Invocation(argv), 'demo', T.Aggregate(
            r'^FAIL mygrep \(gate mode\): ' + label,
            'demo_record.py prints one PASS/FAIL line, no rows'),
            baseline=T.Invocation(CLI))])


T.main('recorder', [source_tooth(*s) for s in SOURCE] +
       [guest_tooth(*g) for g in GUEST])
