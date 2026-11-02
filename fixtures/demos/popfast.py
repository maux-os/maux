"""A popover inside fast(): its box would be dropped with the frames.

scripts/check_recorder.py runs this in GATE mode and requires it to be
refused. Not under site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='popfast',
    title='A popover inside fast()',
    backend='text80',
    image='play',
    gate='check-demo-popfast',
)


def run(t):
    t.run_cmd_echoed('echo result', 'echo')
    t.expect_lines(['result'], 'echo result')
    with t.fast(4):
        t.popover('IYKYK ;-)', 1)
