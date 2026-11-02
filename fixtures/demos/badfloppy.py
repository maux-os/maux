"""Names a floppy that does not exist (scripts/check_recorder.py): the
loader must refuse it by name. Never run."""
DEMO = dict(
    name='badfloppy',
    title='No such floppy',
    backend='text80',
    image='play',
    floppy='nosuchdisk',
    gate='check-demo-badfloppy',
)


def run(t):
    pass
