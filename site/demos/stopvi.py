"""W20 -- stop vi, run make, carry on (docs/SITE.md sec 4).

Job control and virtual consoles together, on a real project. On console
1 a person opens examples/hello's hello.s in vi and makes an edit that is
NOT saved, stops vi with ^Z, and starts make in the background (a
foreground make would hold the console, and chvt is a program, so there
is nothing to type it into). While make builds, chvt 2 moves the glass to
a second console, where ps shows vi stopped (T) in its own bank and make
and its child running in theirs. chvt 1 comes back; wait waits for make;
and the first build, which could only read the disk, is the OLD
greeting. fg brings vi back, the buffer and the cursor where they were
(the next key lands right after the edit), :wq saves, and make builds
the new one.

What is asserted, and why a film that merely looked right would not pass:

  * the vi screen after fg, bar its bottom row, is the vi screen before
    ^Z: the same rows;
  * ps on console 2 holds the PID vi had (state T) and the PID the shell
    printed for make (state R or S, in the bank that is its PID), and a
    child of make: PIDs read off the glass, never typed here and never
    in a label;
  * console 1 is exactly as it was left, plus the chvt 2 line and a
    fresh prompt (the twocons check);
  * the build.log make wrote while vi was stopped, the OLD program's
    output (hello, world), the file the new vi saved (the host derives
    its last line from examples/hello/hello.s), and the NEW program's
    output (hello, world, again.).

No timing-dependent text is in a checkpoint label (the twocons lesson).

The film's clock card is pinned off (docs/RECORDER.md), so every file has
one date and a plain make after the save prints nothing (the film shows
that), so it runs make clean first. With a clock card ProDOS would still
date only to the minute, and maux make treats an equal date as not
newer, so the edit, made about 50 s after the build, would also be
invisible: the film's caption says both.

NOTE for whoever adds ps's COMMAND column (ps-args): the two `grep -v ' 1$'`
lines below drop the rows whose PPID is 1 by matching the end of the line,
and ps_rows() reads the first four fields. Once a row no longer ends in the
PPID both must change together, or the filter hides nothing and the two
displays can disagree about a console shell's R or S.
"""
import os
import re

import demo_host as H

DEMO = dict(
    name='stopvi',
    title='Stop vi, run make, carry on',
    backends=('text80', 'ut'),
    image='full',
    gate='check-demo-stopvi',
)

EXAMPLE = os.path.join(H.ROOT, 'examples', 'hello')
OLD = 'hello, world'
NEW = 'hello, world, again.'
# build.log, in the order make writes it now that MAKE-FLUSH is in:
# each command line, then what that command said. It used to be
# recorded the other way round -- nas's message ahead of the line that
# caused it -- because make left liba's buffer unflushed across the
# spawn. Same shape as REBUILD below, which always read correctly
# because a console is line-buffered.
BUILD_LOG = ['nas -o hello.o hello.s',
             'nas: 32 bytes -> hello.o',
             'ld -o hello hello.o -L /usr/lib -l a']
REBUILD = ['nas -o hello.o hello.s',
           'nas: 40 bytes -> hello.o',
           'ld -o hello hello.o -L /usr/lib -l a']
SAME_ROWS = 23          # vi's text rows; the row under them is its status
# make's own PID. It is deterministic -- make is spawned at a fixed
# point in this script, before any build spawn takes a bank -- and the
# three ps filters below name it LITERALLY rather than interpolating
# it, because site/build.py renders a demo's commands by evaluating
# them statically and a runtime value is not evaluable. The script
# asserts the real pid equals this, so if it ever moves the film fails
# with that sentence instead of with three silent mismatches.
MAKE_PID = 11


def example_last_line():
    """hello.s's last line, as the host reads it from the example."""
    with open(os.path.join(EXAMPLE, 'hello.s'), 'rb') as f:
        lines = f.read().decode('ascii').rstrip('\n').split('\n')
    return lines[-1]


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


def ps_rows(rows):
    """[(pid, state, bank, ppid)] of a `ps` listing."""
    out = []
    for r in rows[1:]:
        f = r.split()
        if len(f) >= 4 and f[0].isdigit():
            out.append((int(f[0]), f[1], f[2], int(f[3])))
    return out


def clear(t):
    t.press('\x0c')
    t.wait_prompt('clear screen')


def run(t):
    old_line = example_last_line()
    t.expect(OLD in old_line and old_line.startswith('MSG'),
             'host: hello.s ends with the greeting line')
    typed_line = old_line.replace("'%s'" % OLD, "'%s, again'" % OLD)
    saved_line = old_line.replace("'%s'" % OLD, "'%s'" % NEW)
    t.expect(typed_line != old_line != saved_line,
             'host: the edits change the line')

    t.say('Job control and two consoles, on a real project.')
    t.say('Bill Joy wrote vi and csh. Jim Kulp gave csh its ^Z.')
    clear(t)
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.run_cmd_echoed('mkdir proj; cd proj', 'a directory of our own')
    t.run_cmd_echoed('cp /usr/src/examples/HELLO/hello.s '
                     '/usr/src/examples/HELLO/Makefile .',
                     'copy the project')
    t.expect_lines(0, 'cp prints nothing')
    clear(t)

    t.say('A small project: hello.s and its Makefile. Open the source.')
    t.run_cmd_echoed('vi hello.s', 'vi')
    t.wait('"hello.s"', 'vi is up on the file')
    t.hold(1.0)
    t.type_human('G')
    t.hold(0.5)
    t.type_human('/world\r')
    t.hold(0.5)
    t.type_human('e')
    t.say('Change the greeting. The edit is in vi, not on the disk yet.')
    t.type_human('a, again')
    t.press(t.ESC)
    t.hold(1.0)
    vi_before = rows_of(t)[:SAME_ROWS]
    t.expect(vi_before[-1] == typed_line,
             'the buffer holds the edited greeting, on its last line')

    t.say('^Z stops vi and gives the shell back.')
    t.press(t.CTRL_Z)
    t.wait_prompt('^Z returns the prompt')
    t.expect(shown(t)[-2:] == ['[1]+ Stopped   vi hello.s', '$'],
             'the shell says vi is Stopped')
    # ps goes to a file; cut trims to the four fixed columns and grep
    # drops the rows whose parent is init (the two console shells): a
    # shell's state at the instant ps looks, R or S, depends on the
    # phase, and the two displays would differ. The cut is what makes
    # ' 1$' mean PPID again now that ps ends each line with COMMAND
    # (PS-ARGS): PID 1-4, S 6, BANK 8-11, PPID 13-16, COMMAND from 18.
    t.run_cmd_echoed('ps > ps.txt', 'ps to a file')
    t.expect_lines(0, 'ps prints nothing to the screen')
    t.say('cut keeps the four fixed columns, grep drops the two console '
          'shells: a shell is R or S depending on the instant ps looks.')
    t.run_cmd_echoed("cut -c1-16 ps.txt | grep -v ' 1$'", 'ps, without the shells')
    rows = t.output('ps with vi stopped')
    stopped = [p for p in ps_rows(rows) if p[1] == 'T']
    t.expect(rows[0].split()[:4] == ['PID', 'S', 'BANK', 'PPID'] and
             len(stopped) == 1 and int(stopped[0][2], 16) == stopped[0][0],
             'ps shows one stopped process, in the bank that is its PID')
    vi_pid = stopped[0][0]
    t.say('The T is vi, stopped, in a bank of its own.')

    t.say('make, in the background, with its output in a file.')
    t.say('Then chvt 2, a second console, while it builds.')
    t.run_cmd_echoed('make > build.log 2>&1 &', 'start make')
    t.wait_prompt('make started')
    started = re.search(r'\[2\] (\d+)', ' '.join(shown(t)))
    t.expect(started is not None, 'the shell prints the job number and PID')
    make_pid = int(started.group(1))
    t.run_cmd_echoed('jobs', 'jobs')
    t.expect_lines(['[1]- Stopped   vi hello.s', '[2]+ Running   make'],
                   'jobs lists vi stopped and make running')
    left = shown(t)             # console 1, exactly as it is left
    t.expect(left[-1] == '$', 'host: console 1 sits at a prompt')

    # No caption from here to the ps below: make is started, and a
    # caption's reading time would eat the build's margin (the ps wants
    # a live child of make; make's nas runs for most of the build).
    t.run_cmd_echoed('chvt 2', 'chvt 2')
    wait_rows(t, lambda r: r[0] == '$' and not any(r[1:]),
              'console 2 is a fresh, blank screen with a prompt')
    t.run_cmd_echoed('ps > ps2.txt', 'ps to a file on console 2')
    t.expect_lines(0, 'ps prints nothing to the screen')
    # make's CHILD is kept off the screen, and this is the one place in
    # the film where that is necessary. Its PID is not deterministic:
    # make spawns nas and ld in turn, each taking the lowest free bank,
    # so which generation of child is alive when ps looks depends on how
    # far the build has got -- and the UltraTerm, which scrolls in
    # hardware, is reliably further along than the //e's 80-column
    # display, which scrolls in software. Measured 2026-11-02: the same
    # keystrokes gave `12 R 0C 11` on text80 and `15 R 0F 11` on ut, so
    # the recorder's "same keys, same text" rule failed on a row that
    # was CORRECT in both. The claim is still made and still proven --
    # the two lines below say how many children make has and what state
    # the one child is in, neither of which names a PID.
    t.expect(make_pid == MAKE_PID,
             'host: make took pid %d, the one the ps filters name'
             % MAKE_PID)
    t.run_cmd_echoed("cut -c1-16 ps2.txt | grep -v ' 1$' | grep -v ' 11$'",
                     'ps on console 2')
    rows = t.output('ps on console 2')
    procs = ps_rows(rows)
    by_pid = {p[0]: p for p in procs}
    t.expect(rows[0].split()[:4] == ['PID', 'S', 'BANK', 'PPID'] and
             len(by_pid) == len(procs) and
             all(int(p[2], 16) == p[0] for p in procs),
             'ps lists distinct processes, each in the bank that is its '
             'PID')
    t.expect(vi_pid in by_pid and by_pid[vi_pid][1] == 'T',
             'vi is still there, stopped')
    t.expect(make_pid in by_pid and by_pid[make_pid][1] == 'S',
             'make itself is blocked, waiting')
    # Both of these cut FIRST, for the same reason the listing above
    # does: a raw ps line ends in COMMAND, so ' <ppid>$' matches
    # nothing until the four fixed columns are all that is left.
    t.run_cmd_echoed("cut -c1-16 ps2.txt | grep -c ' 11$'",
                     'how many children')
    t.expect_lines(['1'], 'make has exactly one child')
    t.run_cmd_echoed("cut -c1-16 ps2.txt | grep ' 11$' | cut -c6",
                     'and what it is doing')
    t.expect_lines(['R'], 'that child is running')
    t.say('vi stopped; make waiting on its child, which runs.')

    t.say('chvt 1: back where the shell is.')
    t.run_cmd_echoed('chvt 1', 'chvt 1')
    wait_rows(t, lambda r: [x for x in r if x] ==
              left[:-1] + ['$ chvt 2', '$'],
              'console 1 is back: its rows as left, then chvt 2 and a '
              'fresh prompt')
    t.say('wait holds the shell until make is done.')
    t.run_cmd_echoed('wait', 'wait')
    with t.fast(16):
        t.expect_lines(0, 'wait prints nothing', seconds=600)
    clear(t)
    t.run_cmd_echoed('cat build.log', 'cat build.log')
    # MAKE-FLUSH is merged (main ef6580ca), so make flushes liba's
    # buffer before each spawn and build.log is in the order a reader
    # expects: the command line, then what the command said. This was a
    # `sorted()` compare while the defect stood, with a TODO to tighten
    # it on exactly this event.
    log = t.expect_lines(len(BUILD_LOG), 'build.log has the three lines')
    t.expect(log == BUILD_LOG,
             'build.log reads in order: make built hello while vi was '
             'stopped')
    t.run_cmd_echoed('./hello', 'run the first build')
    t.expect_lines([OLD], 'the first build says the OLD greeting')
    t.say('The old greeting. make read the disk; vi\'s edit was not there.')

    clear(t)
    t.say('fg, and vi is back as it was.')
    t.run_cmd_echoed('fg %1', 'fg')
    t.wait('hello, world, again', 'the buffer is back on the screen')
    t.hold(2.0)
    wait_rows(t, lambda r: r[:SAME_ROWS] == vi_before,
              'vi shows the same rows it showed before ^Z')
    t.say('The cursor is where it was too: append a full stop here.')
    t.type_human('a.')
    t.press(t.ESC)
    t.hold(1.0)
    t.type_human(':wq')
    t.enter()
    t.wait_prompt('vi quit')
    clear(t)
    t.run_cmd_echoed('tail -1 hello.s', 'the saved greeting line')
    t.expect_lines([saved_line], 'the file holds the edit and the full stop')

    t.say('Now make again, to pick up the edit.')
    t.run_cmd_echoed('make', 'make sees nothing')
    t.expect_lines(0, 'make says nothing: the edit is not newer')
    t.say('This film runs with no clock card, so every file has one date.')
    t.say('With one, ProDOS still dates only to the minute.')
    t.say('Either way make sees nothing. So: clean first.')
    t.run_cmd_echoed('make clean', 'make clean')
    t.expect_lines(['rm -f hello hello.o'], 'make clean removes the outputs')
    t.run_cmd_echoed('make', 'make again')
    with t.fast(16):
        rows = t.output('make rebuilds', seconds=600)
    t.expect(rows == REBUILD, 'make assembles with nas, then links')
    t.run_cmd_echoed('./hello', 'run the new build')
    t.expect_lines([NEW], 'the new build says the new greeting')
    t.poster()
    t.say('The old joke: make love. V7\'s make answered: Don\'t know how to make love. Stop.')
    t.run_cmd_echoed('make love', 'make love')
    t.expect_lines(['make: no rule to make target love'],
                   'make has no rule for love either')
    t.hold(2.0)
