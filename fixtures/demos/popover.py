"""A planted popover, for the recorder's popover rows.

scripts/check_recorder.py records this and requires the box's pixels on
every frame of the popover window (60 frames) and on no other frame,
the picture otherwise the emulator's own, and a poster that is the clean
picture although poster() is called immediately before the popover. It is not under site/demos/, so check-demos never runs
it.
"""
DEMO = dict(
    name='popover',
    title='A planted popover',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-popover',
)


def run(t):
    t.run_cmd_echoed('echo result', 'echo')
    t.expect_lines(['result'], 'echo result')
    t.hold(1.0)
    t.poster()                       # the NEXT frame: a popover one
    t.popover('IYKYK ;-)', 2)
    t.hold(1.0)
