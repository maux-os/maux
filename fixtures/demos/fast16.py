"""A planted fast(16) segment, for the recorder's speed-badge row.

scripts/check_recorder.py runs this in record mode and requires the
kept frames inside the segment to carry the x16 badge and a cycle
count that rises 16 frames' worth per kept frame. It is not under
site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='fast16',
    title='A sixteen-times segment',
    backend='text80',
    image='play',
    gate='check-demo-fast16',
)


def run(t):
    t.run_cmd_echoed('echo before', 'before')
    t.expect_lines(['before'], 'echo before')
    with t.fast(16):
        t.hold(8.0)                  # 240 frames stepped, 15 kept
    t.run_cmd_echoed('echo after', 'after')
    t.expect_lines(['after'], 'echo after')
