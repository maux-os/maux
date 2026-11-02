"""W5 -- ^C, ^Z, jobs, fg (docs/SITE.md sec 4, docs/DEMOS-W1.md).

Process control on a 6502. A long pipeline is killed with ^C and the
shell is back at once; `ps` proves nothing of it is left. Then an
editor is suspended with ^Z, `jobs` names it, and `fg` puts it back on
the screen exactly where it was.

The "nothing is left" claim is a count, not a feeling: ps is run
before the pipeline and after the ^C and the rows must be the same
processes (same PIDs, hence the same banks).
"""
import demo_host as H

DEMO = dict(
    name='jobs',
    title='^C, ^Z, jobs and fg',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-jobs',
)


def pids(rows):
    return [r.split()[0] for r in rows[1:]]


def parents(rows):
    return {r.split()[0]: r.split()[3] for r in rows[1:]}


def run(t):
    t.say('Job control. V7 Unix had none.')
    t.say('Jim Kulp added it to csh; 4.1BSD shipped it in 1981.')
    t.say('First, what is running now.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.run_cmd_echoed('ps', 'ps before')
    ps0 = t.output('ps before')
    before = pids(ps0)
    t.expect(len(before) >= 3, 'ps lists the shell and its friends')
    t.hold(1.5)

    t.say('Start a pipeline that will not finish soon, in the background.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('sleep 60 | sleep 60 > /dev/null &', 'start pipeline')
    t.hold(1.0)
    t.wait_prompt('job started')
    t.run_cmd_echoed('ps', 'ps during')
    ps1 = t.output('ps during')
    during = pids(ps1)
    new = [p for p in during if p not in before]
    t.expect(len(during) == len(before) + 2 and len(new) == 2,
             'ps now lists two more processes: the two sleeps')
    t.expect(all(parents(ps1)[p] == parents(ps1)[during[-1]]
                 for p in new),
             'both are children of the shell that started them')
    t.hold(2.0)

    t.say('fg brings it to the front. ^C.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('fg', 'fg')
    t.hold(2.0)
    live = [r.rstrip() for r in t.screen() if r.strip()]
    t.expect(live[-1] == 'sleep 60 | sleep 60',
             'the pipeline is in the foreground: no prompt yet')
    t.press(t.CTRL_C)
    t.wait_prompt('^C returns the prompt')
    t.run_cmd_echoed('ps', 'ps after')
    after = pids(t.output('ps after'))
    t.expect(after == before,
             'the same processes as before: both sleeps are gone')
    t.hold(2.0)

    t.say('Now an editor. ^Z stops it and gives the shell back.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('vi notes', 'vi')
    t.wait('~', 'vi is up')
    t.hold(1.0)
    t.type_human('ihello from the editor')
    t.press(t.ESC)
    t.hold(1.0)
    t.press(t.CTRL_Z)
    t.wait_prompt('^Z returns the prompt')
    rows = [r.rstrip() for r in t.screen() if r.strip()]
    t.expect(rows[-2:] == ['[1]+ Stopped   vi notes', '$'],
             'the shell says the editor is Stopped')
    t.hold(1.0)

    t.say('jobs lists it; fg brings it back, text intact.')
    t.run_cmd_echoed('jobs', 'jobs')
    t.expect_lines(['[1]+ Stopped   vi notes'], 'jobs names the editor')
    t.hold(1.5)
    t.run_cmd_echoed('fg', 'fg')
    # not the last character: the cursor cell is drawn as another glyph
    t.wait('hello from the edit', 'the buffer is back on the screen')
    t.hold(1.5)
    t.type_human(':wq')
    t.enter()
    t.wait_prompt('vi quit')
    t.run_cmd_echoed('cat notes', 'cat')
    t.expect_lines(['hello from the editor'], 'the text survived ^Z and fg')
    t.say('A shell, a job table, signals, on a 1 MHz 65C02.')
    t.poster()
    t.hold(1.0)
