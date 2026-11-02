#!/usr/bin/env python3
"""check_init.py -- pid 1 brings the console shell back.

WHY. Measured 2026-09-20 on this image: typing `exit` at the console
prompt removed the only shell, and nothing replaced it. The kernel and
the scheduler kept running, the tty kept echoing what you typed, and no
program would ever execute again -- a reboot was the only recovery.
There is no other init to fall back on: the boot program spawns one
shell and that is the whole of userland's bootstrap
(docs/COVER-OFF.md sec 1).

pid 1 now respawns it, with a rate limit, because a shell that dies the
instant it starts would otherwise spin the machine.

WHAT THIS ASSERTS
  1. after `exit`, a shell is running again and it is a DIFFERENT pid;
  2. the new shell actually works -- a command typed at it runs;
  3. pid 1's own respawn counter went up, so the shell came back
     BECAUSE init restarted it and not by some other accident;
  4. the rate limiter is armed rather than decorative: pid 1's
     too-fast-exit counter is 0 after an ordinary, unhurried exit;
  5. the BOOT SCRIPT, both ways round. On the shipped image there is
     no /etc/RC, and a missing one must be silent -- pid 1 comes
     up and records no rc pid. Then a SECOND phase makes its own
     writable copy of the image, adds an rc to it from the shell the
     way a person would, reboots, and checks it ran: the rc's own
     side effect is there and pid 1 recorded a pid for it. Adding one
     to a disk that had none is the case a user actually lives in.

  6. (KFIX7) INIT NEVER ABANDONS THE CONSOLE. It used to park for good
     ($E5, `bra *`) after INIT_FLAPN fast deaths in a row, and at the
     first failed spawn ($EE): nothing ever ran on that console again.
     Unix inits said "respawning too rapidly" and tried again later; so
     does this one. Phases below, each on its own machine; the
     thresholds are READ from src/test/playtestb.s, not retyped:
       flap     INIT_FLAPN fast `exit`s (after the boot shell's own,
                which is not fast) -> a line on the console, no shell,
                then (INIT_BACKH x 256 ticks later) a working shell,
                counter reset; and a SUSTAINED flap for 40 emulated
                seconds spawns a bounded number of shells (the rate
                limit still prevents a spin: unbounded measured 156);
       rawmsg   (KFIX8) the same back-off with the console RAW (OPOST
                off): the line must not be overprinted by the next
                prompt (it ended in a bare CR, a newline only under
                OPOST; it ends in ESC E now);
       shadowmsg (KFIX9) text a dying shell wrote with no trailing CR
                must not come back at ^L at the next shell's prompt:
                the ^L replay shadow ends at ESC E like it does at CR;
       nosh     /bin/sh renamed away, then `exit`: the spawn fails, init
                says so and waits, the file comes back, the shell
                returns;
       cold     a BRK left poked into the retained shell bank: the
                respawned shell must load COLD (KBRK R1 drops the lazy-
                free tag of a SIGTRAP death) and work;
       coop     init's mode cell forced to 3 (a real no-tick boot takes
                no keys): INIT_COOPN respawns are COUNTED (there is no
                clock to time them), then the back-off, and the shell
                is back;
       frozen   a boot where the tick COUNTER is frozen but the mode
                reads 1 (K_TIMER_FORCE=1 arms no IRQ) and /bin/sh cannot
                be spawned: the back-off must END (its poll has a
                syscall-count ceiling) and init must try again, again.
     A machine with no advancing tick takes no keystrokes (keyboard
     polling rides the tick hook), so no phase can wait for a key.

TEETH (2026-09-20): with pid 1's loop reverted to its old spawn-wait-
park shape, (1) times out -- no prompt ever returns.
TEETH (2026-10-18, KFIX7): see docs/KFIX7-NOTES.md sec 1 -- the base
(init parks) is RED on flap/nosh/coop/frozen; a back-off of zero length
is RED on the duration and spawn-rate rows; KBRK R1 removed is RED on
cold; the COOP respawn count removed is RED on coop; the poll
ceiling removed is RED on frozen.
"""
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_race as GR                                  # noqa: E402
import check_vi as V                                      # noqa: E402
import check_brk as B                                     # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402

PCB_ARRY_ADDR = 0x0800
PCB_ENT = 16
PCB_COUNT = 48
PCB_STATE, PCB_BANK, PCB_PARENT = 1, 3, 4
LIVE = (1, 2, 3)                      #: RUNNABLE / RUNNING / BLOCKED

R_RESPAWN = 0x1213                    #: src/test/playtestb.s
R_FAST = 0x1214
R_RCPID = 0x1218                      #: pid /etc/RC got, 0 = none
R_DONE, R_ERR, R_STEP = 0x1210, 0x1211, 0x1212
R_BACKOFF = 0x121A                    #: back-offs init has taken
PLAYTESTB = os.path.join(V.ROOT, 'src', 'test', 'playtestb.s')


def equ(name):
    """An `equ` value out of the init source: the gate asserts the
    build's own thresholds, never a retyped copy."""
    with open(PLAYTESTB, encoding='ascii') as fh:
        for line in fh:
            m = re.match(rf'{name}\s+equ\s+(\d+)', line)
            if m:
                return int(m.group(1))
    raise RuntimeError(f'{name} not found in {PLAYTESTB}')


INIT_BACKH = equ('INIT_BACKH')        #: back-off = this x 256 ticks
INIT_FLAPN = equ('INIT_FLAPN')        #: fast deaths in a row
INIT_COOPN = equ('INIT_COOPN')        #: respawns counted with no tick
INIT_POLLH = equ('INIT_POLLH')        #: poll ceiling, x 256 syscalls
BACKOFF_MSG = 'init: shell failed, retrying'
MLI_NOFILE = 0x46
LISTING = os.path.join(V.ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')


def pcb_table(c):
    r = c.call_tool('peek', {'addr': PCB_ARRY_ADDR,
                             'count': PCB_COUNT * PCB_ENT,
                             'bank': 'aux', 'aux_bank': 0})
    return r.get('bytes') or r.get('data')


def live_pids(c):
    t = pcb_table(c)
    return {p for p in range(1, PCB_COUNT)
            if t[p * PCB_ENT + PCB_STATE] in LIVE}


def bank_of(c, pid):
    return pcb_table(c)[pid * PCB_ENT + PCB_BANK]


def rc_pid(c):
    b = bank_of(c, 1)
    r = c.call_tool('peek', {'addr': R_RCPID, 'count': 1,
                             'bank': 'aux', 'aux_bank': b})
    return (r.get('bytes') or r.get('data'))[0]


def init_counters(c):
    """R_RESPAWN / R_FAST out of pid 1's OWN bank -- pid 1 runs a copy
    of the parent span in its bank, so these are not main-memory
    cells."""
    b = bank_of(c, 1)
    r = c.call_tool('peek', {'addr': R_RESPAWN, 'count': 2,
                             'bank': 'aux', 'aux_bank': b})
    d = r.get('bytes') or r.get('data')
    return d[0], d[1]


def at_prompt(rs):
    nb = [r for r in rs if r.strip()]
    return bool(nb) and re.fullmatch(r'\$( \$)*', nb[-1].strip()) is not None


def step(c, n=1):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def _rc_phase():
    """Add an rc to a disk that had none, reboot, see it run."""
    out = []
    tmp = tempfile.mkdtemp(prefix='maux-rc-')
    disk = os.path.join(tmp, 'rc.po')
    shutil.copyfile(V.DISK, disk)
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    try:
        c.initialize()
        # write-through, NOT copy: the rc has to survive the reboot
        for attempt in range(2):
            r = c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
            if not r.get('ok'):
                raise RuntimeError(f'reset failed: {r}')
            r = c.call_tool('mount_disk', {'path': disk, 'unit': 1})
            if r.get('ok') is False:
                raise RuntimeError(f'mount_disk failed: {r}')
            V.settle(c, at_prompt, 'shell prompt', max_steps=3000)
            if attempt == 0:
                # a person adding a boot script, with no quoting tricks
                V.t(c, 'mkdir /etc\r')
                step(c, 40)
                V.t(c, 'echo mkdir /etc/RCRAN > /etc/RC\r')
                step(c, 60)
                print('[check-init] rc written to a fresh copy; rebooting')
                continue
            rcp = rc_pid(c)
            if rcp == 0:
                out.append(
                    'after adding /etc/RC and rebooting, pid 1 '
                    'recorded no rc pid -- it never spawned the boot '
                    'script (src/test/playtestb.s INIT_RC)')
            else:
                print(f'[check-init] boot script spawned as pid {rcp}')
            V.t(c, 'ls /etc\r')
            ran = False
            for _ in GR.polls(c, 200):
                if any('RCRAN' in r for r in V.rows(c)[:-1]):
                    ran = True
                    break
            if not ran:
                out.append(
                    "the boot script left no trace: /etc/RC did "
                    "not run, or ran and failed. pid 1 spawning it is "
                    "not the same as it working")
            else:
                print('[check-init] boot script RAN (its side effect is '
                      'on the disk)')
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
        shutil.rmtree(tmp, ignore_errors=True)
    return out


# --------------------------------------------------------------------
# KFIX7: init never abandons the console
# --------------------------------------------------------------------
class Clock:
    """Emulated cycles stepped through one client."""

    def __init__(self, c):
        self.c = c
        self.cyc = 0

    def step(self, n=50_000):
        self.c.call_tool('step', {'cycles': n})
        self.cyc += n

    def typ(self, text):
        self.c.call_tool('type', {'text': text})
        for _ in range(max(4, len(text) + 2)):
            self.step()


def init_state(c):
    b = bank_of(c, 1)
    r = c.call_tool('peek', {'addr': R_DONE, 'count': 11,
                             'bank': 'aux', 'aux_bank': b})
    d = r.get('bytes') or r.get('data')
    return {'done': d[0], 'err': d[1], 'step': d[2], 'resp': d[3],
            'fast': d[4], 'bo': d[10]}


def shells(c):
    return sorted(live_pids(c) - {1, 2})


def msg_count(c):
    return sum(r.count(BACKOFF_MSG) for r in V.rows(c))


def exit_until_backoff(ck, limit, failures, label, before=None):
    """Type `exit` at each fresh shell until init backs off. Returns
    the number of exits typed, or None."""
    c = ck.c
    exits = 0
    while exits < limit:
        st = init_state(c)
        if st['bo']:
            return exits
        resp = st['resp']
        # a hook that returns true typed its own exit line (shadowmsg:
        # the dying shell's last words must come AFTER the Enter)
        if not (before and before()):
            ck.typ('exit\r')
        exits += 1
        for _ in range(GR.count(600, 50_000)):
            ck.step(GR.quantum(50_000))
            st = init_state(c)
            if st['resp'] != resp or st['bo']:
                break
        else:
            parked = (' -- init PARKED (the old give-up)'
                      if st['done'] in (0xE5, 0xEE) and not st['bo'] else '')
            failures.append(f'{label}: exit #{exits} produced neither a '
                            f'respawn nor a back-off '
                            f'(state {st}, shells {shells(c)}){parked}')
            return None
    st = init_state(c)
    if not st['bo']:
        failures.append(f'{label}: {exits} fast exits and init never '
                        f'backed off (state {st})')
        return None
    return exits


def wait_for_shell(ck, max_steps, step=200_000):
    for _ in range(GR.count(max_steps, step)):
        ck.step(GR.quantum(step))
        if shells(ck.c):
            return True
    return False


def shell_works(ck, failures, label):
    c = ck.c
    try:
        V.settle(c, at_prompt, f'{label}: a prompt', max_steps=600)
    except AssertionError as e:
        failures.append(f'{label}: no prompt from the shell init brought '
                        f'back: {str(e)[:200]}')
        return False
    ck.typ('echo BACKOK\r')
    for _ in range(GR.count(200, 50_000)):
        ck.step(GR.quantum(50_000))
        if any('BACKOK' in r for r in V.rows(c)[:-1]):
            return True
    failures.append(f'{label}: the shell init brought back reached a '
                    f'prompt but did not run a command')
    return False


def fresh(failures_unused=None):
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    c.initialize()
    V.boot(c)
    return c


def flap_phase():
    """Five fast deaths -> a back-off (not a park); then recovery; then
    a sustained flap spawns a bounded number of shells."""
    out = []
    c = fresh()
    try:
        ck = Clock(c)
        n = exit_until_backoff(ck, INIT_FLAPN + 4, out, 'flap')
        if n is None:
            return out
        # the boot shell's own exit lives long and is not fast; the
        # next INIT_FLAPN are, and the last of them trips the limit
        if n != INIT_FLAPN + 1:
            out.append(f'flap: backed off after {n} exits; the limit is '
                       f'INIT_FLAPN={INIT_FLAPN} FAST deaths after the '
                       f'boot shell\'s own, so {INIT_FLAPN + 1}')
        st = init_state(c)
        t_bo = ck.cyc
        print(f'[check-init] flap: {n} fast exits -> init backs off '
              f'(state {st})')
        if st['done'] != 0xE5:
            out.append(f'flap: R_DONE is ${st["done"]:02X} during the '
                       f'back-off, expected $E5')
        if shells(c):
            out.append(f'flap: shells {shells(c)} alive during the '
                       f'back-off')
        if st['bo'] != 1:
            out.append(f'flap: R_BACKOFF={st["bo"]}, expected 1')
        for _ in range(4):
            ck.step(200_000)
        if msg_count(c) != 1:
            out.append(f'flap: the console shows {msg_count(c)} copies of '
                       f'{BACKOFF_MSG!r}, expected exactly one; screen: '
                       f'{[r.rstrip() for r in V.rows(c) if r.strip()][-4:]}')
        # THE WAIT IS REAL: no spawn for most of the back-off ...
        resp0 = st['resp']
        for _ in range(GR.count(40)):             # ~8 emulated seconds
            ck.step(GR.quantum(200_000))
            if init_state(c)['resp'] != resp0 or shells(c):
                out.append(f'flap: init respawned {(ck.cyc - t_bo) / 1e6:.1f}'
                           f' M cycles into a {INIT_BACKH * 256 / 60:.1f} s '
                           f'back-off -- it is not waiting')
                break
        # ... and then the shell comes back.
        if not wait_for_shell(ck, 150):
            out.append('flap: init never brought a shell back after the '
                       'back-off (the old behaviour: parked)')
            return out
        waited = (ck.cyc - t_bo) / 1e6
        lo = INIT_BACKH * 256 * 1e6 / 60 / 1e6 * 0.9
        print(f'[check-init] flap: shell back after {waited:.1f} M cycles '
              f'(back-off is {INIT_BACKH * 256 / 60:.1f} s)')
        if waited < lo:
            out.append(f'flap: shell back after only {waited:.1f} M cycles; '
                       f'the back-off is {INIT_BACKH * 256 / 60:.1f} s')
        st = init_state(c)
        if shell_works(ck, out, 'flap'):
            st = init_state(c)
            if st['fast'] != 0 or st['done'] != 0xAA or st['bo'] != 1:
                out.append(f'flap: after the back-off the counters are '
                           f'{st}; expected fast=0 done=$AA bo=1')
            else:
                print('[check-init] flap: the shell works; counter reset, '
                      'R_DONE back to $AA')
        # SUSTAINED FLAP: the rate limit still prevents a spin.
        resp_a = init_state(c)['resp']
        t_a = ck.cyc
        typed = None
        for _ in range(int(40e6 / 50_000)):
            ck.step()
            st = init_state(c)
            if shells(c) and typed != (st['resp'], st['bo']):
                c.call_tool('type', {'text': 'exit\r'})
                typed = (st['resp'], st['bo'])
        spawns = init_state(c)['resp'] - resp_a
        secs = (ck.cyc - t_a) / 1e6
        bound = 25                                  # unbounded is ~100
        print(f'[check-init] flap: {spawns} shells spawned in '
              f'{secs:.0f} emulated seconds of non-stop `exit` '
              f'(bound {bound})')
        if spawns > bound:
            out.append(f'flap: {spawns} spawns in {secs:.0f} emulated '
                       f'seconds of sustained flapping, bound {bound}: the '
                       f'rate limit no longer prevents a spin')
        if spawns < 3:
            out.append(f'flap: only {spawns} spawns in {secs:.0f} s of '
                       f'sustained flapping -- the driver is vacuous')
    finally:
        c.close()
    return out


def rawmsg_problem(rows, row):
    """None when `rows[row]` is the whole back-off line and a prompt
    is on the row below it; else the complaint. The message may sit
    on the LAST row: no row below is a failure of this phase, not an
    IndexError (KFIX9, review of KFIX8)."""
    below = rows[row + 1] if row + 1 < len(rows) else None
    if rows[row] == BACKOFF_MSG and below is not None \
            and below.startswith('$'):
        return None
    return (f'rawmsg: after the shell came back row {row} is '
            f'{rows[row]!r} and the next row is {below!r}: the '
            f'prompt overprinted the message, ran on from it, or '
            f'has no row')


def _rawmsg_selftest():
    """The verdict on a message at the bottom of the glass, a prompt
    below it, an overprinted row and a missing row below."""
    good = [BACKOFF_MSG, '$']
    assert rawmsg_problem(good, 0) is None
    assert rawmsg_problem([BACKOFF_MSG], 0), 'last row: no row below'
    assert rawmsg_problem([BACKOFF_MSG, 'x'], 0), 'no prompt below'
    assert rawmsg_problem(['', BACKOFF_MSG], 1), 'last row of two'


def rawmsg_phase():
    """The back-off line with the console RAW (KFIX8 item 5). init's
    message used to end in a bare CR, a newline only under OPOST; a
    full-screen program (or `stty -opost`) leaves the console raw, and
    then the next shell's prompt landed on the message's own row and
    overprinted its head (`$ )t: shell failed, retrying`). The line now
    ends in ESC E (NEL: column 0 + index in either mode). Each shell
    here switches OPOST off before it exits, so the back-off line is
    written to a raw console; asserts the row holds the whole line, the
    prompt of the shell that comes back is on the row after it, and
    there is exactly one copy."""
    out = []
    c = fresh()
    try:
        ck = Clock(c)
        n = exit_until_backoff(ck, INIT_FLAPN + 4, out, 'rawmsg',
                               before=lambda: ck.typ('stty -opost\r'))
        if n is None:
            return out
        for _ in range(4):
            ck.step(200_000)
        rows = [r.rstrip() for r in V.rows(c)]
        hits = [i for i, r in enumerate(rows) if r == BACKOFF_MSG]
        if len(hits) != 1:
            out.append(f'rawmsg: with OPOST off the back-off line is not '
                       f'on a row of its own, once: rows {rows[:12]}')
            return out
        if not wait_for_shell(ck, 150):
            out.append('rawmsg: no shell came back after the back-off')
            return out
        for _ in range(20):
            ck.step(200_000)
        rows = [r.rstrip() for r in V.rows(c)]
        bad = rawmsg_problem(rows, hits[0])
        if bad:
            out.append(bad)
            return out
        print('[check-init] rawmsg: OPOST off -- the back-off line is '
              'whole and the new prompt is on the next row')
    finally:
        c.close()
    return out


def shadowmsg_phase():
    """The ^L shadow must not outlive the back-off line (KFIX9, review
    of KFIX8). The line ends in ESC E (NEL); the shadow reset at CR and
    not at NEL, so text a dying shell wrote with NO trailing CR stayed in
    it, and ^L at the next shell's prompt repainted that text before the
    `$`. Every shell here writes high-bit text (`echo -n DEAD`, typed on
    the keyboard, so recorded) and exits on the same line; the Enter that
    ran it has already reset the shadow, so only what the shell WROTE is
    in it. After the back-off and the next prompt, ^L must repaint the
    prompt and nothing else."""
    out = []
    c = fresh()
    try:
        ck = Clock(c)
        n = exit_until_backoff(
            ck, INIT_FLAPN + 4, out, 'shadowmsg',
            before=lambda: ck.typ('echo -n DEAD; exit\r') or True)
        if n is None:
            return out
        for _ in range(4):
            ck.step(200_000)
        if not wait_for_shell(ck, 150):
            out.append('shadowmsg: no shell came back after the back-off')
            return out
        for _ in range(20):
            ck.step(200_000)
        ck.typ('\x0c')
        for _ in range(20):
            ck.step(200_000)
        live = [r.rstrip() for r in V.rows(c) if r.strip()]
        if live != ['$']:
            out.append(f'shadowmsg: ^L at the respawned prompt repainted '
                       f'more than the prompt: {live!r} -- the dead '
                       f'shell\'s text outlived the back-off line')
        else:
            print('[check-init] shadowmsg: ^L at the new prompt repaints '
                  'only the prompt')
    finally:
        c.close()
    return out


# nosh's restorer must fire AFTER init's first failed spawn of /bin/sh and
# BEFORE init's first retry (INIT_BACKH x 256 ticks = ~12.8 s later). The
# failed spawn follows the harness's `exit` by ~0.3M, and the harness
# gets there ~4.5M after the arming line (typing, two prompt waits) --
# ~7.5M under MAUX_GATE_RACE=late, which adds 3M of lag after the line;
# the guest starts the restorer's sleep ~1.4M after it. 11 s puts the
# restore at ~12.6M: ~4.8M after the failed spawn when the harness is
# late, ~5M before the retry when it is not. nosh_phase asserts both
# halves: the restorer is still pending at `exit`, and init backed off.
NOSH_RESTORE = 11


def nosh_phase():
    """/bin/sh gone when the shell exits: init says so and retries."""
    out = []
    c = fresh()
    try:
        ck = Clock(c)
        # the file comes back from a background job that outlives the
        # shell, NOSH_RESTORE s after it is armed (init's first retry is
        # ~13 s after its failed spawn)
        base = set(shells(c))
        ck.typ(f'( sleep {NOSH_RESTORE} ; mv /bin/shx /bin/sh ) &\r')
        restorer = set()
        for _ in range(GR.count(60)):          # the job exists: a property
            restorer = set(shells(c)) - base
            if restorer:
                break
            ck.step(GR.quantum(200_000))
        else:
            out.append('nosh: the background restorer never appeared in '
                       'the PCB table')
            return out
        V.settle(c, at_prompt, 'nosh: the restorer is armed', max_steps=300)
        ck.typ('mv /bin/sh /bin/shx\r')
        V.settle(c, at_prompt, 'nosh: /bin/sh renamed away', max_steps=300)
        if not (restorer & set(shells(c))):
            out.append('nosh: the overlap did not happen: the restorer '
                       'had already put /bin/sh back before the harness '
                       'moved it away (guest faster than the harness '
                       'pace, or the harness late; raise NOSH_RESTORE)')
            return out
        ck.typ('exit\r')
        st = None
        for _ in range(GR.count(400, 50_000)):
            ck.step(GR.quantum(50_000))
            st = init_state(c)
            if st['bo']:
                break
        else:
            out.append(f'nosh: init never backed off after the spawn of '
                       f'a missing /bin/sh failed (state {st}, shells '
                       f'{shells(c)}, screen '
                       f'{[r.rstrip() for r in V.rows(c) if r.strip()][-3:]}'
                       f') -- the old behaviour parks at $EE')
            return out
        print(f'[check-init] nosh: spawn failed, init backs off '
              f'(state {st})')
        if st['err'] != MLI_NOFILE or st['step'] != 1:
            out.append(f'nosh: R_ERR=${st["err"]:02X} R_STEP={st["step"]}, '
                       f'expected ${MLI_NOFILE:02X} / 1 (a failed spawn)')
        if st['done'] != 0xE5:
            out.append(f'nosh: R_DONE=${st["done"]:02X}, expected $E5')
        for _ in range(4):
            ck.step(200_000)
        if msg_count(c) != 1:
            out.append(f'nosh: {msg_count(c)} copies of {BACKOFF_MSG!r} on '
                       f'the console, expected one')
        if not wait_for_shell(ck, 200):
            out.append('nosh: /bin/sh was restored but init never brought '
                       'a shell back')
            return out
        if shell_works(ck, out, 'nosh'):
            print('[check-init] nosh: /bin/sh is back and so is the shell')
    finally:
        c.close()
    return out


def cold_phase():
    """A BRK left in the retained shell bank must not come back."""
    out = []
    c = fresh()
    try:
        ck = Clock(c)
        t = pcb_table(c)
        row = t[3 * PCB_ENT:4 * PCB_ENT]
        bank, sp = row[PCB_BANK], row[5]

        def pk(addr, n, ab):
            r = c.call_tool('peek', {'addr': addr, 'count': n,
                                     'bank': 'aux', 'aux_bank': ab})
            return r.get('bytes') or r.get('data')
        fr = pk(0x100 + sp + 1, 6, bank)
        pc = fr[4] | (fr[5] << 8)
        orig = pk(pc, 1, bank)[0]
        c.call_tool('poke', {'addr': pc, 'bytes': [0], 'bank': 'aux',
                             'aux_bank': bank})
        ck.typ('echo hi\r')            # the shell BRKs; SIGTRAP; respawn
        for _ in range(GR.count(400)):
            ck.step(GR.quantum(200_000))
            if init_state(c)['resp'] >= 1 and shells(c):
                break
        else:
            out.append('cold: init never respawned the BRKed shell '
                       f'(state {init_state(c)})')
            return out
        now = pk(pc, 1, bank)[0]
        if now != orig:
            out.append(f'cold: the respawned shell is WARM: the BRK poked '
                       f'into the retained bank is still there '
                       f'(${now:02X}, the image has ${orig:02X}) -- '
                       f'KBRK R1 must drop the lazy-free tag of a SIGTRAP '
                       f'death')
        if shell_works(ck, out, 'cold') and now == orig:
            print(f'[check-init] cold: the respawned shell loaded cold '
                  f'(poke gone) and works')
    finally:
        c.close()
    return out


def coop_phase():
    """No tick source: INIT_RATE counts respawns instead of timing
    them (INIT_COOPN), then backs off.

    A machine with NO tick takes no keystrokes at all (keyboard polling
    rides the tick hook; measured 2026-10-18 by booting the play image
    with K_TIMER_FORCE=3 -- the prompt paints, nothing typed is read),
    so the branch cannot be driven on a real no-tick boot. It is driven
    here by poking init's own mode cell (R_TMODE) while the shell lives:
    INIT_RATE and INIT_BACKOFF both read it, and the real tick keeps
    running underneath, which is what lets this gate type `exit`."""
    out = []
    c = fresh()
    try:
        ck = Clock(c)
        b = bank_of(c, 1)

        def force_coop():
            c.call_tool('poke', {'addr': 0x1217, 'bytes': [3],
                                 'bank': 'aux', 'aux_bank': b})
        n = exit_until_backoff(ck, 40, out, 'coop', before=force_coop)
        if n is None:
            return out
        t_bo = ck.cyc
        print(f'[check-init] coop: no tick; backed off after {n} exits '
              f'(state {init_state(c)})')
        if n != INIT_COOPN:
            out.append(f'coop: backed off after {n} exits; with no tick '
                       f'init counts respawns and gives way at INIT_COOPN '
                       f'({INIT_COOPN})')
        if not wait_for_shell(ck, 600, step=50_000):
            out.append('coop: init never brought a shell back after the '
                       'back-off')
            return out
        waited = (ck.cyc - t_bo) / 1e6
        print(f'[check-init] coop: shell back after {waited:.1f} M cycles')
        if waited < INIT_BACKH * 256 * 1e6 / 60 / 1e6 * 0.9:
            out.append(f'coop: shell back after only {waited:.1f} M cycles')
        if shell_works(ck, out, 'coop'):
            st = init_state(c)
            if st['fast'] != 0 or st['done'] != 0xAA:
                out.append(f'coop: counters after the back-off: {st}')
    finally:
        c.close()
    return out


def frozen_phase():
    """A tick COUNTER that never advances while the mode reads 1: the
    back-off's poll must end on its syscall ceiling and init must try
    again. K_TIMER_FORCE=1 (poked at ENTRY, timer.s) sets the mode and
    arms no IRQ, so the counter is frozen; /bin/sh's path text is
    poked so the spawn fails and init goes straight to the back-off
    (a no-tick machine takes no keys, so nothing can be typed to make
    a shell die). Red on an unbounded poll: R_BACKOFF stays 1."""
    out = []
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    try:
        c.initialize()
        r = c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        if not r.get('ok'):
            raise RuntimeError(f'reset failed: {r}')
        r = c.call_tool('mount_disk', {'path': V.DISK, 'unit': 1,
                                       'copy': True})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        hit = c.call_tool('until_pc', {'pc': B.sym(LISTING, 'ENTRY'),
                                       'max_cycles': 200_000_000})
        if not hit.get('hit'):
            out.append(f'frozen: never reached ENTRY ({hit})')
            return out
        c.call_tool('poke', {'addr': B.sym(LISTING, 'K_TIMER_FORCE'),
                             'bytes': [1], 'bank': 'main'})
        # "/bin/sh" -> "/bin/sx": the text init copies into its bank
        c.call_tool('poke', {'addr': B.sym(LISTING, 'SHBIN_PTH_TXT') + 6,
                             'bytes': [0xF8], 'bank': 'main'})
        ck = Clock(c)
        for _ in range(40):
            ck.step(500_000)
        b = bank_of(c, 1)

        def tick():
            r = c.call_tool('peek', {'addr': 0x1078, 'count': 5,
                                     'bank': 'aux', 'aux_bank': b})
            d = r.get('bytes') or r.get('data')
            return d[0], d[1] | (d[2] << 8)
        st = init_state(c)
        if not st['bo']:
            out.append(f'frozen: init never backed off (state {st})')
            return out
        m0, t0 = tick()
        for _ in range(10):
            ck.step(500_000)
        m1, t1 = tick()
        if m0 != 1 or t0 != t1:
            out.append(f'frozen: the fixture is vacuous (mode {m0}, tick '
                       f'{t0} -> {t1}; wanted mode 1 and a frozen count)')
            return out
        print(f'[check-init] frozen: mode {m0}, tick stuck at {t0}; '
              f'back-off #{st["bo"]} in progress')
        # the ceiling is INIT_POLLH x 256 syscalls (~1.1 k cycles each)
        for _ in range(int(1.6 * INIT_POLLH * 256 * 1100 / 500_000)):
            ck.step(500_000)
            st = init_state(c)
            if st['bo'] >= 2:
                break
        else:
            out.append(f'frozen: still in back-off #{st["bo"]} after '
                       f'{ck.cyc / 1e6:.0f} M cycles on a frozen tick: the '
                       f'poll has no ceiling (state {st})')
            return out
        if st['err'] != MLI_NOFILE or shells(c):
            out.append(f'frozen: unexpected state after the ceiling: {st}, '
                       f'shells {shells(c)}')
        else:
            print(f'[check-init] frozen: the poll ended on its ceiling and '
                  f'init tried again (back-off #{st["bo"]} at '
                  f'{ck.cyc / 1e6:.0f} M cycles)')
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    return out


def main():
    _rawmsg_selftest()
    if not os.path.exists(V.DISK):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    failures = []
    try:
        c.initialize()
        V.boot(c)
        # 5a. NO boot script on the shipped image: a missing rc must
        #     be silent and normal, not an error and not a delay.
        rcp = rc_pid(c)
        if rcp != 0:
            failures.append(
                f'pid 1 recorded rc pid {rcp} on an image with no '
                f'/etc/RC -- a missing boot script must be silent')
        else:
            print('[check-init] no boot script on this image, and pid 1 '
                  'came up anyway')

        before = live_pids(c)
        resp0, fast0 = init_counters(c)
        shells = sorted(before - {1, 2})
        print(f'[check-init] at the prompt: live {sorted(before)}, '
              f'pid 1 respawns={resp0} fast={fast0}')
        if not shells:
            raise AssertionError('no console shell at boot at all')
        old_sh = shells[-1]

        # Let the shell live longer than the flap threshold before
        # killing it, so this models an ORDINARY exit rather than a
        # crash loop -- otherwise the rate limiter is right to count it
        # and the fast==0 assertion below would be asserting a bug.
        step(c, 20)                                   # ~4 s emulated

        V.t(c, 'exit\r')
        resp1 = resp0
        for _ in GR.polls(c, 400):
            resp1, _f = init_counters(c)
            if resp1 > resp0:
                break
        if resp1 <= resp0:
            failures.append(
                f'after `exit` pid 1 never respawned the shell: counter '
                f'stuck at {resp0}, live pids {sorted(live_pids(c))}, '
                f'last screen row '
                f'{[r.rstrip() for r in V.rows(c) if r.strip()][-1:]!r} '
                f'-- docs/COVER-OFF.md sec 1')
        else:
            # A REUSED pid is correct: the slot was freed. What matters
            # is that a working shell is there, so prove it by running
            # something, not by comparing pid numbers.
            now = sorted(live_pids(c) - {1, 2})
            print(f'[check-init] `exit` killed pid {old_sh}; pid 1 '
                  f'respawned ({resp0} -> {resp1}), shells now {now}')
            V.settle(c, at_prompt, 'a prompt from the respawned shell')
            V.t(c, 'echo INITOK\r')
            ok = False
            for _ in GR.polls(c, 200):
                if any('INITOK' in r for r in V.rows(c)[:-1]):
                    ok = True
                    break
            if not ok:
                failures.append(
                    'the respawned shell reached a prompt but did not RUN '
                    'a command -- it is not a working shell')
            else:
                print('[check-init] the respawned shell ran a command')

        # 6. ^D at the respawned prompt (2026-10-08, operator: "ctrl-d on
        #    the root shell does the same repaint shenanigans" -- the
        #    screen showed `$ $`). EOF is an exit too, so pid 1 respawns
        #    again; the point of THIS phase is the screen: the cooked ^D
        #    echoes nothing, so the leaving shell must end its own
        #    prompt row (one CR to stderr, shlex.s :realeof) or the new
        #    prompt lands two cells into the old one. Assert the row the
        #    old prompt was on holds exactly one prompt and the new
        #    prompt is on the row after it.
        resp2 = resp1
        step(c, 20)                                   # unhurried again
        rows_before = [r.rstrip() for r in V.rows(c)]
        prompt_row = max(i for i, r in enumerate(rows_before) if r.strip())
        V.t(c, '\x04')
        for _ in GR.polls(c, 400):
            resp2, _f = init_counters(c)
            if resp2 > resp1:
                break
        if resp2 <= resp1:
            failures.append(
                f'after ^D at the prompt pid 1 never respawned the shell: '
                f'counter stuck at {resp1} -- EOF must be an exit')
        else:
            V.settle(c, at_prompt, 'a prompt from the shell respawned after ^D')
            rows_after = [r.rstrip() for r in V.rows(c)]
            old_row = rows_after[prompt_row] if prompt_row < len(rows_after) else ''
            new_row = rows_after[prompt_row + 1] if prompt_row + 1 < len(rows_after) else ''
            if old_row != '$' or not new_row.startswith('$'):
                failures.append(
                    f'^D at the prompt: expected the old prompt row to stay '
                    f'`$` and the respawned prompt on the next row, got '
                    f'row {prompt_row}={old_row!r} row {prompt_row + 1}='
                    f'{new_row!r} -- the `$ $` repaint')
            else:
                print('[check-init] ^D at the prompt: the respawned prompt '
                      'starts a fresh row')
            _r, _fast = init_counters(c)
            resp1 = resp2

        _r, fast1 = init_counters(c)
        if fast1 != 0:
            failures.append(
                f'pid 1 counted an unhurried exit as a fast one '
                f'(fast={fast1} after a shell that lived well past the '
                f'{120}-tick threshold): the rate limiter would give up '
                f'on a live machine')
        else:
            print('[check-init] rate limiter armed and not tripped by an '
                  'ordinary exit (fast=0)')
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    failures += _rc_phase()
    for phase in (flap_phase, rawmsg_phase, shadowmsg_phase, nosh_phase,
                  cold_phase, coop_phase, frozen_phase):
        failures += phase()

    for f in failures:
        print(f'[check-init] FAIL: {f}', file=sys.stderr)
    if failures:
        return 1
    print('[check-init] PASS: `exit` at the console prompt no longer ends '
          'the session -- pid 1 respawns the shell, the new one works, '
          'and the flap limiter is armed without being tripped')
    return 0


if __name__ == '__main__':
    sys.exit(main())
