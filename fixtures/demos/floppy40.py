"""A text40 demo with a floppy in slot 6 (scripts/check_recorder.py).

The floppy is mounted before boot(), so boot()'s text40 pokes survive
and the console is 40 columns wide: a 50-character line wraps to two
rows. Were the floppy mounted after the pokes, the slot mount would
cold-reset them away and the console would come up native 80, one row.
Not under site/demos/, so check-demos never runs it.
"""
DEMO = dict(
    name='floppy40',
    title='Forty columns, a floppy in slot 6',
    backend='text40',
    image='play',
    floppy='ddshrink',
    gate='check-demo-floppy40',
)


def run(t):
    t.expect(t.floppy is not None, 'a floppy is in the drive')
    t.run_cmd_echoed('echo ' + 'x' * 50, 'a 50-character line')
    t.expect_lines(['x' * 40, 'x' * 10],
                   'it wraps at 40 columns: the console is text40')
