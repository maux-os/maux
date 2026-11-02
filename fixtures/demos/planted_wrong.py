"""A planted failure: the expectation is wrong on purpose.

scripts/check_recorder.py runs this in record mode and requires the
recording to abort with nothing left in the output directory. It is
not under site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='planted_wrong',
    title='A demo whose expectation is wrong',
    backend='text80',
    image='play',
    gate='check-demo-planted_wrong',
)


def run(t):
    t.say('This demo is meant to fail.')
    t.run_cmd_echoed('echo hello', 'echo')
    t.expect_text('goodbye', 'echo prints hello, not goodbye')
