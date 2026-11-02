"""hold(0) must step no frame (a dwell of zero is no dwell).

scripts/check_recorder.py records this and requires zero output frames
and zero emulated cycles. It is not under site/demos/, so check-demos
never runs it.
"""
DEMO = dict(
    name='hold0',
    title='A zero-second hold',
    backend='text80',
    image='play',
    gate='check-demo-hold0',
)


def run(t):
    t.hold(0)
    t.hold(0.0)
    t.hold(0.01)                     # under half a frame: also nothing
