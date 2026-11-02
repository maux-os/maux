"""W1 -- the first minute (docs/SITE.md sec 4, docs/DEMOS-W1.md).

Boot is already done by the harness. A person looks around: `ls`, how
many programs are in /bin, a pipeline through three of them, and `ps`.
The idea of the whole project is in the last column of `ps`: every row
is a process, and every process is a 64K RamWorks bank, so the BANK
column equals the PID.

Nothing here is typed from memory. The root listing, the program count
and the pipeline's rows are all derived from build/play.po by a2til
(scripts/demo_host.py), the very file the guest booted a copy of.
"""
import demo_host as H

DEMO = dict(
    name='firstmin',
    title='ls, a pipeline and ps',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-firstmin',
    hero=True,
)


def run(t):
    root = H.names('/')
    nbin = len(H.names('/BIN'))
    top = sorted(H.names('/BIN'), reverse=True)[:5]

    t.say('A Unix on an Apple IIe. The boot is done.')
    t.say('No ] prompt and no CALL -151. This is a shell.')
    t.press('\x0c')
    t.wait_prompt('clear screen')

    t.run_cmd_echoed('ls', 'ls')
    rows = t.output('ls')
    t.expect(H.columns_to_names(rows) == root,
             'ls prints the volume root, in order')
    t.hold(2.0)

    t.say('The programs live in /bin. How many?')
    t.run_cmd_echoed('ls /bin | wc -l', 'count')
    t.expect_lines([str(nbin)], 'wc counts exactly the files on the disk')
    t.hold(2.0)

    t.say('A pipeline: ls, sort and head. The last five names.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('ls /bin | sort -r | head -5', 'pipeline')
    t.expect_lines(top, 'the pipeline prints the last five names, in order')
    t.say('Make each program do one thing well.')
    t.say('McIlroy, Bell System Technical Journal, 1978.')

    t.say('And ps. Look at the BANK column.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('ps', 'ps')
    rows = t.output('ps')
    t.expect(rows and rows[0].split()[:4] == ['PID', 'S', 'BANK', 'PPID'],
             'ps prints its header')
    procs = [r.split() for r in rows[1:]]
    t.expect(len(procs) >= 3, 'ps lists several processes')
    procs = [p[:4] for p in procs]
    t.expect(all(len(p) == 4 for p in procs) and
             len({p[0] for p in procs}) == len(procs) and
             len({p[2] for p in procs}) == len(procs),
             'ps prints distinct PIDs and distinct banks')
    t.expect(all(int(p[0]) == int(p[2], 16) for p in procs),
             'every process sits in the bank that is its PID')
    t.say('Every process is a 64K RamWorks bank: BANK is PID.')
    t.poster()
    t.hold(1.0)
