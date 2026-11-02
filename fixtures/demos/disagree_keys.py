"""A planted disagreement between the two displays, for check-recorder.

Each display passes this demo on its own; on the UltraTerm it types one
key more (a typo planted in one backend's keys). The rule is the same
keys and the same text on every display a demo declares, so the CLI must
call this red and name the keys. Not under site/demos/, so check-demos
never runs it.
"""
DEMO = dict(
    name='disagree_keys',
    title='Two displays, two sets of keys',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-disagree_keys',
)


def run(t):
    t.run_cmd_echoed('echo hi' + ('!' if t.backend == 'ut' else ''), 'echo')
    t.expect(True, 'it ran')
