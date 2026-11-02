"""Captions: one beat, then one caption over output (no keys).

scripts/check_recorder.py records this and checks the VTT: every cue
ends exactly at its beat end, no key falls inside a cue, the first key
after a plain say() waits out the quiet pause, and every cue carries the
centring settings. Not under site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='capover',
    title='Caption beats',
    backend='text80',
    image='play',
    gate='check-demo-capover',
)


def run(t):
    t.say('A plain caption: the screen holds, then the typing starts.')
    t.run_cmd_echoed('echo one', 'echo one')
    t.expect_lines(['one'], 'echo one')
    t.run_cmd_echoed('sleep 4', 'a wait with nothing to type')
    t.say('Narration over a wait: it may overlap output, never keys.',
          over=True)
    t.hold(1.0)                     # output only; the cue is still open
    t.endcue()
    t.press('\x0c')
    t.wait_prompt('clear screen')
