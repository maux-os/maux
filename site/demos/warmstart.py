"""W19 -- the second time is faster (docs/SITE.md sec 4).

When a process exits, the kernel keeps its bank instead of freeing it,
tagged with the file whose code is in it (src/kernel/lazyfree.s, "lazy
free"; docs/STICKY.md sec 25-27). The next launch of the same file is
handed that bank back and skips the open, the read loop and the copy of
the image. What it still pays for: the kernel's own spawn work, one
GET_FILE_INFO that checks the file's date, one zeroed page, and the
program itself, which starts again from its first instruction. A write to
the file drops the tag, so the next launch is cold again.

The film shows all three states, each timed in emulated cycles from
RETURN to the first output (to within one video frame, 34,016 cycles,
rounded up):

  vi, on a new file: cold, then warm. The time is to vi's file banner.
  a copy of nas (/tmp/asm, so that its path is new): cold, then warm,
  then cold again after the file is rewritten by cp. The time is to nas's
  usage line.

The figures go into the captions (so each display's film says what ITS
run measured) and, through t.measure(), into the film's stamp, where the
watch page reads them. They are never in a checkpoint label: the two
displays differ. MEASURE_CAPTIONS binds each figure to the words right
before it in the published cue (scripts/demo_stamp.py, film_errors).
"""
import demo_host as H

DEMO = dict(
    name='warmstart',
    title='The second time is faster',
    backends=('text80', 'ut'),
    image='full',
    gate='check-demo-warmstart',
)

# What each measured figure is, in the caption that states it: the words
# right before "N.NN million".
MEASURE_CAPTIONS = {
    'vi_cold': 'vi, the first time:',
    'vi_warm': 'vi again, warm:',
    'asm_cold': 'asm, a new file, the first time:',
    'asm_warm': 'asm again, warm:',
    'asm_rewritten': 'asm after the file was rewritten:',
}
MEASURE_ORDER = [('vi_warm', 'vi_cold'),
                 ('asm_warm', 'asm_cold'),
                 ('asm_warm', 'asm_rewritten')]

USAGE = 'usage: nas [-o obj] src'
VI_BANNER = '"scratch" ['
# a launch that reuses nothing costs at least this many times a warm one
# for nas (measured 7x; the bound is loose on purpose)
NAS_RATIO = 2.0
FRAME = 34_016          # one video frame: the resolution of every figure


def cycle(t):
    return t.c.call_tool('step', {'cycles': 0})['cycle']


def millions(n):
    return "%.2f million" % (n / 1e6)


def timed(t, cmd, ready, label):
    """The command is typed and echoed; press RETURN and count the
    emulated cycles until READY(rows) holds on the glass (to within one
    video frame, 34,016 cycles, rounded up). Returns the cycles."""
    t.last_cmd = cmd
    start = cycle(t)
    t.press('\r', cyc=FRAME)
    for _ in range(3000):
        rows = [r.rstrip() for r in t.screen()]
        if ready(rows):
            return cycle(t) - start
        t._slice(FRAME)
    raise AssertionError(label + ': the output never appeared; screen:\n' +
                         '\n'.join(r for r in rows if r))


def usage_up(rows):
    return USAGE in rows


def vi_up(rows):
    return any(r.startswith(VI_BANNER) for r in rows)


def clear(t):
    t.press('\x0c')
    t.wait_prompt('clear screen')


def leave_vi(t):
    t.hold(1.0)
    t.type_human(':q')
    t.enter()
    t.wait_prompt('vi quit')


def run(t):
    t.say('Run a program once, and the second launch is faster.')
    t.say('When a process exits, the kernel keeps its bank.')
    t.say('The bank is tagged with the file whose code is in it.')
    t.say('Launch that file again and the same bank comes back, code intact.')
    t.say('V7 had a sticky bit to keep a program\'s text in swap.')
    t.say('Here the kernel keeps the bank without being asked.')
    t.say('A stock IIe has no cache. Here the bank is the cache.')
    clear(t)
    t.say('Each launch is timed from RETURN to the first output.')

    # --- vi: cold, then warm ------------------------------------------
    t.run_cmd_echoed('cd /tmp', 'a scratch directory')
    clear(t)
    t.say('vi, first. Nothing has run it since boot.')
    t.wait_prompt('vi: prompt before')
    t.type_and_expect_echo('vi scratch', 'vi, cold')
    vi_cold = timed(t, 'vi scratch', vi_up, 'vi, cold')
    t.expect(vi_up([r.rstrip() for r in t.screen()]),
             'vi is up on a new file')
    t.say('vi, the first time: %s cycles.' % millions(vi_cold))
    leave_vi(t)
    clear(t)
    t.say('Again. The kernel finds vi\'s bank waiting.')
    t.wait_prompt('vi: prompt before')
    t.type_and_expect_echo('vi scratch', 'vi, warm')
    vi_warm = timed(t, 'vi scratch', vi_up, 'vi, warm')
    t.expect(vi_up([r.rstrip() for r in t.screen()]),
             'vi is up on a new file again')
    t.say('vi again, warm: %s cycles.' % millions(vi_warm))
    t.say('vi still starts up and draws its screen. The load is what went.')
    leave_vi(t)

    # --- a copy of nas: cold, warm, rewritten --------------------------
    clear(t)
    t.say('Now nas, the assembler, copied to a new name.')
    t.run_cmd_echoed('cp /bin/nas /tmp/asm', 'copy nas')
    t.expect_lines(0, 'cp prints nothing')
    t.say('A kept bank is tagged with a path. A new path is a new file.')
    clear(t)
    t.wait_prompt('asm: prompt before')
    t.type_and_expect_echo('/tmp/asm', 'asm, cold')
    asm_cold = timed(t, '/tmp/asm', usage_up, 'asm, cold')
    t.expect_lines([USAGE], 'nas with no arguments prints its usage')
    t.say('asm, a new file, the first time: %s cycles.' % millions(asm_cold))
    clear(t)
    t.wait_prompt('asm: prompt before')
    t.type_and_expect_echo('/tmp/asm', 'asm, warm')
    asm_warm = timed(t, '/tmp/asm', usage_up, 'asm, warm')
    t.expect_lines([USAGE], 'the same usage line, the second time')
    t.poster()
    t.say('asm again, warm: %s cycles.' % millions(asm_warm))
    t.say('Same program, same file: only the load is gone.')
    t.say('The kernel still checks the file\'s date before it reuses a bank.')

    clear(t)
    t.say('Write to the file, and the kept bank is dropped.')
    t.run_cmd_echoed('cp /bin/nas /tmp/asm', 'rewrite asm')
    t.expect_lines(0, 'cp prints nothing')
    clear(t)
    t.wait_prompt('asm: prompt before')
    t.type_and_expect_echo('/tmp/asm', 'asm, rewritten')
    asm_rewritten = timed(t, '/tmp/asm', usage_up, 'asm, rewritten')
    t.expect_lines([USAGE], 'nas prints its usage after the rewrite')
    t.say('asm after the file was rewritten: %s cycles.'
          % millions(asm_rewritten))
    t.say('Phil Karlton: two hard things, cache invalidation and naming things.')
    t.say('A program that needs a bank can take a kept one back.')

    # what the run measured goes into the film's stamp (t.measure); the
    # page quotes it. A plausible range, and the order the story needs.
    for name, n in (('vi_cold', vi_cold), ('vi_warm', vi_warm),
                    ('asm_cold', asm_cold), ('asm_warm', asm_warm),
                    ('asm_rewritten', asm_rewritten)):
        t.measure(name, n)
        assert 50_000 < n < 8_000_000, (name, n)
    for lo, hi in MEASURE_ORDER:
        assert t.measures[lo] < t.measures[hi], (lo, hi, t.measures)
    assert asm_cold > NAS_RATIO * asm_warm, (asm_cold, asm_warm)
    assert asm_rewritten > NAS_RATIO * asm_warm, (asm_rewritten, asm_warm)
    t.hold(1.0)
