"""Prints the date and a file's modification time: the two places the
Timemaster clock reaches the screen.

scripts/check_recorder.py records this twice and requires identical frame
hashes. With the Timemaster pinned off (demo_record.PINNED_CLOCK) the
guest has no time at all and `date` says so; with the host clock seeded
into the card it prints the host's minute, which differs from one
recording to the next. The expect_* calls below are what turn that
second case red. It is not under site/demos/, so check-demos never
runs it.
"""
DEMO = dict(
    name='clockdate',
    title='What the clock says',
    backend='text80',
    image='play',
    gate='check-demo-clockdate',
)


def run(t):
    t.run_cmd_echoed('date', 'date')
    t.expect_lines(['date: no valid clock reading'],
                   'no host time reaches the guest')
    t.run_cmd_echoed('echo x > stamp', 'create a file')
    t.expect_lines(0, 'creating a file prints nothing')
    t.run_cmd_echoed('ls -l stamp', 'its mtime')
    rows = t.output('ls -l')
    t.expect(len(rows) == 1 and rows[0].split()[-2:] == ['-', 'stamp'],
             'the file carries no date: the guest clock is off')
