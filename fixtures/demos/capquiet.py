"""A key sent exactly at the end of an over-cue owes the quiet pause.

scripts/check_recorder.py records this and requires the key to land at
least the quiet pause after the cue's end. Not under site/demos/.
"""
DEMO = dict(
    name='capquiet',
    title='The quiet pause after an over-caption',
    backend='text80',
    image='play',
    gate='check-demo-capquiet',
)


def run(t):
    t.say('Short caption.', over=True)      # 2.4 s, the floor
    t.hold(2.4)                             # to the exact end of the cue
    t.press('\x0c')                         # must wait out the 0.45 s
    t.wait_prompt('clear screen')
