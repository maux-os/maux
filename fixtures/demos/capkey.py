"""A key sent while a say(over=True) caption is on screen.

scripts/check_recorder.py runs this in GATE mode and in RECORD mode and
requires RecorderError naming this demo and the caption. Not under
site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='capkey',
    title='A key under a caption',
    backend='text80',
    image='play',
    gate='check-demo-capkey',
)


def run(t):
    t.run_cmd_echoed('echo result', 'echo')
    t.expect_lines(['result'], 'echo result')
    t.say('This caption narrates a wait, not typing.', over=True)
    t.hold(0.5)
    t.press('x')                    # refused: the cue is still open
