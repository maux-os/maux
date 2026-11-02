"""fast() entered while a say(over=True) cue is open.

scripts/check_recorder.py runs this in GATE and RECORD mode and requires
RecorderError in both (gate time and output frames would disagree about
when the cue ends). Not under site/demos/.
"""
DEMO = dict(
    name='capoverfast',
    title='fast() under an over-caption',
    backend='text80',
    image='play',
    gate='check-demo-capoverfast',
)


def run(t):
    t.run_cmd_echoed('echo result', 'echo')
    t.expect_lines(['result'], 'echo result')
    t.say('A caption over a wait.', over=True)
    with t.fast(4):
        t.hold(1.0)
