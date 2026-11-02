"""A real disagreement of TEXT between the two displays, for
check-recorder: the same keys, but the machine itself answers
differently. `vidmode` with no argument prints the console's video mode,
and the console on the //e's 80 columns says `80X24 VT` where the
UltraTerm console says `80X24 HQ VT`. Each display passes this demo on its
own (it expects what its own console says); together the recorder must
call them different, by the scraped screen alone -- no checkpoint is
substituted. Not under site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='disagree_text',
    title='Two displays, two screens',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-disagree_text',
)


def run(t):
    t.run_cmd_echoed('vidmode', 'vidmode')
    t.expect_lines(['80X24 HQ VT' if t.backend == 'ut' else '80X24 VT'],
                   'vidmode says which console this is')
