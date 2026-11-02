"""A popover with a glyph the font lacks (an e acute).

scripts/check_recorder.py runs this in GATE mode and requires it to be
refused, so a bad popover goes red in the sweep, not only on the Mac at
`make demos`. Not under site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='popbad',
    title='A popover with a missing glyph',
    backend='text80',
    image='play',
    gate='check-demo-popbad',
)


def run(t):
    t.run_cmd_echoed('echo result', 'echo')
    t.expect_lines(['result'], 'echo result')
    t.popover('IYKYK \u00e9', 1)
