"""A demo whose run() raises something that is neither an assertion nor
a wedge. scripts/check_recorder.py runs it first and a good demo second
through the CLI, and requires the second to still run (`make demos`
reports one broken demo and goes on). Not under site/demos/.
"""
DEMO = dict(
    name='raises',
    title='A demo that raises',
    backend='text80',
    image='play',
    gate='check-demo-raises',
)


def run(t):
    raise RuntimeError('boom: a bug in the demo, not an expectation')
