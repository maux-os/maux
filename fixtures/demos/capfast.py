"""say() inside fast(): the cue would be timed in dropped frames.

scripts/check_recorder.py runs this in GATE and RECORD mode and requires
RecorderError in both. Not under site/demos/.
"""
DEMO = dict(
    name='capfast',
    title='A caption inside fast()',
    backend='text80',
    image='play',
    gate='check-demo-capfast',
)


def run(t):
    t.run_cmd_echoed('echo result', 'echo')
    t.expect_lines(['result'], 'echo result')
    with t.fast(4):
        t.say('A caption inside fast.')
