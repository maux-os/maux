"""W13 -- two consoles, one machine (docs/SITE.md sec 4).

A job runs on console 1 (a twelve-step loop, one tick every five
seconds, each tick appended to a file in /tmp). `chvt 2` moves the glass
to a second console with a shell of its own, where vi is used and
quit. `chvt 1` comes back: console 1 is exactly as it was left, and
the log shows the loop kept running while console 2 was in use.

What is asserted, and why it cannot be satisfied by a stopped job:

  * console 1's screen is snapshotted before `chvt 2`; after `chvt 1`
    it must be those rows, exactly, plus the `chvt 2` line and a fresh
    prompt;
  * the log is read on console 2 (k_mid ticks), and again on console 1
    after the job is killed (k_end ticks); k_end - k_mid must be at
    least two, ticks that can only have landed AFTER the first read,
    while the machine was showing console 2 and then switching back;
  * the ticks are 1..k in order, with no gap, and k_end is less than
    the twelve the loop would make: the job was alive, and the film
    did not outlast it.

The exact k is the emulated clock's and is not asserted.
"""
import demo_host as H

DEMO = dict(
    name='twocons',
    title='Two consoles, one machine',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-twocons',
)

STEPS = 12      # 12 ticks, 5 s apart: outlasts the captions' beats
SCRIPT = ['for i in 1 2 3 4 5 6 7 8 9 10 11 12',
          'do',
          'echo tick $i >> log',
          'sleep 5',
          'done']
NOTE = 'written on console two'
MIN_GAIN = 2


def rows_of(t):
    return [r.rstrip() for r in t.screen()]


def shown(t):
    return [r for r in rows_of(t) if r]


def wait_rows(t, pred, label, slices=400):
    for _ in range(slices):
        if pred(rows_of(t)):
            t.expect(True, label)          # checkpoints the screen
            return
        t._slice()
    t.expect(False, label)


def ticks(rows):
    """k, for a `cat log` whose rows are tick 1..k in order, no gap."""
    ok = rows == ['tick %d' % n for n in range(1, len(rows) + 1)]
    return len(rows) if ok else None


def run(t):
    t.say('Two consoles. First, a job on this one:')
    t.say('a loop that ticks into a log file every five seconds.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.run_cmd_echoed('cat > tick', 'start the script')
    for line in SCRIPT:
        t.type_line(line, 'script line ' + line)
    t.press(t.CTRL_D)
    t.wait_prompt('script written')
    t.run_cmd_echoed('sh tick > /dev/null &', 'start the job')
    t.hold(2.0)
    t.wait_prompt('job started')
    t.hold(1.0)
    left = shown(t)             # console 1, exactly as it is left
    t.expect(left[-1] == '$', 'host: console 1 sits at a prompt')

    t.say('chvt 2: a second console, with a shell of its own.')
    t.run_cmd_echoed('chvt 2', 'chvt 2')
    wait_rows(t, lambda r: r[0] == '$' and not any(r[1:]),
              'console 2 is a fresh, blank screen with a prompt')
    t.hold(1.5)

    t.say('Use vi over here.')
    t.run_cmd_echoed('cd /tmp', 'console 2 works in /tmp too')
    t.run_cmd_echoed('vi note', 'vi')
    t.wait('~', 'vi is up')
    t.hold(1.0)
    t.type_human('i' + NOTE)
    t.press(t.ESC)
    t.hold(1.0)
    t.type_human(':wq')
    t.enter()
    t.wait_prompt('vi quit')
    t.run_cmd_echoed('cat note', 'cat note')
    t.expect_lines([NOTE], 'console 2 wrote its file')
    t.say('Is the job still ticking? Look at the log from here.')
    t.hold(2.5)         # mid-interval: a read ON a 5 s tick boundary would
                        # show a different count on the two displays
    t.run_cmd_echoed('cat log', 'cat log on console 2')
    k_mid = ticks(t.output('cat log on console 2'))
    t.expect(k_mid is not None and k_mid >= 1,
             'the log is ticks 1..k, in order, k at least 1')
    t.hold(3.0)

    t.say('chvt 1: back where the job is. Same screen, exactly.')
    t.run_cmd_echoed('chvt 1', 'chvt 1')
    wait_rows(t, lambda r: shown_eq(r, left[:-1] + ['$ chvt 2', '$']),
              'console 1 is back: its rows as left, then chvt 2 and a '
              'fresh prompt')

    t.say('Stop the job, and read the log again.')
    t.hold(2.5)         # off the tick boundary, as above
    t.run_cmd_echoed('kill %1', 'kill the job')
    t.expect_lines(['[1]+ Terminated   sh tick'],
                   'the shell reports the job Terminated')
    t.hold(3.0)
    t.run_cmd_echoed('cat log', 'cat log on console 1')
    rows = [r for r in t.output('cat log on console 1')
            if r.startswith('tick')]
    k_end = ticks(rows)
    t.expect(k_end is not None and k_end - k_mid >= MIN_GAIN,
             'at least %d more ticks landed after the first read, while '
             'console 2 was in use and the glass was switching back'
             % MIN_GAIN)
    # The counts k_mid and k_end are the emulated clock's and depend on
    # where a read falls against the 5 s tick: they are asserted as
    # properties, never put in a checkpoint label (the two displays'
    # labels must agree), and not recorded as measures (a stamp measure
    # needs a caption that states it).
    t.expect(k_end < STEPS, 'the job was still running (under %d ticks)'
             % STEPS)
    t.say('The job ticked on the whole time. Two consoles, one machine.')
    t.say('V6\'s process switch is marked: "You are not expected to '
          'understand this."')
    t.say('Here the switch is a write to $C073 and a few soft switches.')
    t.poster()
    t.hold(1.0)


def shown_eq(rows, want):
    return [r for r in rows if r] == want
