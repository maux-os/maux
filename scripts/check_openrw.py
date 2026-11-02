#!/usr/bin/env python3
"""check_openrw.py -- `>` and `>>` wait out a transient other opener
(`make check-openrw`, docs/OPEN-RW-1.md, docs/OPEN-RW-1-NOTES.md).

Boots the play image and types each row at the shell, the
check_shprefix.py idiom (check_shfd's helpers are imported).

THE DEFECT.  ProDOS (and PRC_OPEN's own guard) refuse a second OPEN of
an open file with $50.  `tail -f LOG` opens LOG for a moment once a
second; a `cmd >> LOG` open that landed inside it drew `sh: cannot
redirect` and the command was dropped.  sh now retries a $50 open for
`>` and `>>`, and ONLY $50, bounded, one tick at a time (shsgrw.s).

Rows (the brief's R1-R5; R6 is scripts/posixutil_interactive.py):
  R1  five `echo sentinel-N >> F` back to back under `tail -f F`, over
      a sweep of start phases: every sentinel exactly once, no
      `cannot redirect`, and the retry counter (OW_SEEN, a write-only
      cell in sh's bank) shows a retry was actually TAKEN somewhere in
      the sweep -- timing alone would let the row pass vacuously.
  R2  the same with `echo x > F`: the file ends as `x`, once.
  R3  `exec 3>F; echo a >&3; echo x >> F` (and `>`): refused after the
      bound, F unchanged (OPEN-RW-2: the holder was `exec 3<F` until a
      reader became joinable; OAPPEND-1: it was `exec 3>>F` until
      `>>` became an append open that joins; a NO-INTENT writer is what
      keeps both refused) (a retried `>` truncated nothing), the shell
      usable.
  R4  R3 with a ^C typed while the shell is asleep in the wait: status
      130, prompt back within a few ticks, no `cannot redirect`.
  R5  every other error fails at once and unretried: a missing
      directory, a write-locked `>` target (counter stays 0).

WAITS.  docs/GATE-PREDICATES.md: a handshake the guest raises, never a
duration.  R4 types ^C only once the shell's own retry counter shows it
is waiting; R1/R2 type ^C only after the last sentinel is on the glass,
below the command's own echo, on two identical polls.

Teeth: scripts/teeth_openrw.py.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_shfd as F  # noqa: E402
import check_devfs as D  # noqa: E402
import gate_race as GR  # noqa: E402
import arena  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OW_MAX = 30           # src/bin/shsgrw.s
TICK = 17030          # one 60 Hz VBL, guest cycles
SENTINELS = 5
END = 'burst-end'
BANKS = range(1, 16)  # a pid IS its bank; the rig has 16 (above
                      # that a peek floats to $FF)
#: a refusal that is not retried: today's 240-320k cycles (the base
#: build, same polling) plus slack; a bound's worth of retries is >1M
AT_ONCE = 25 * TICK


class Rig:
    def __init__(self, client, syms):
        self.c = client
        self.seen_addr = syms['OW_SEEN']
        self.stamp_addr = syms['SEGSTAMP']
        self.magic = syms['SEG_MAGIC']

    # -- the retry counter -------------------------------------------
    def peek1(self, bank, addr):
        r = self.c.call_tool('peek', {'addr': addr, 'count': 1,
                                      'bank': 'aux', 'aux_bank': bank})
        d = r.get('bytes') or r.get('data')
        return d[0] if d else 0

    def sh_banks(self):
        """The banks that hold an sh. The counter's address is a
        scratch byte in every OTHER program's bank (a read there is
        another program's data, a write corrupts it), so a bank counts
        only if SEGSTAMP, which only sh writes, holds SEG_MAGIC."""
        return [b for b in BANKS
                if self.peek1(b, self.stamp_addr) == self.magic]

    def seen(self):
        """{bank: OW_SEEN} for every sh bank where it is nonzero."""
        out = {}
        for b in self.sh_banks():
            v = self.peek1(b, self.seen_addr)
            if v:
                out[b] = v
        return out

    def clear_seen(self):
        for b in self.sh_banks():
            self.c.call_tool('poke', {'addr': self.seen_addr,
                                      'bytes': [0], 'bank': 'aux',
                                      'aux_bank': b})

    # -- the glass ----------------------------------------------------
    def rows(self):
        return D.screen_rows(self.c)

    def live(self):
        return [r.rstrip() for r in self.rows() if r.strip()]

    def type(self, text):
        self.c.call_tool('type', {'text': text})


def below(rows, anchor):
    """Rows under the LAST row that equals `anchor` (None if absent)."""
    idx = None
    for i, r in enumerate(rows):
        if r.rstrip() == anchor:
            idx = i
    return None if idx is None else [r.rstrip() for r in rows[idx + 1:]
                                     if r.strip()]


def settle(rig, anchor, pred, label, failures, polls=900, q=50_000):
    """Poll until `pred(rows below anchor)` holds on two identical
    consecutive polls.  Returns (rows below, cycles stepped)."""
    held = None
    cyc = 0
    reg = None
    for _ in GR.polls(rig.c, polls, q):
        cyc += GR.quantum(q)
        reg = below(rig.rows(), anchor)
        if reg is not None and pred(reg):
            if held == reg:
                return reg, cyc
            held = reg
        else:
            held = None
    failures.append(f'{label}: timed out ({polls} polls) waiting for '
                    f'its condition; the glass below {anchor!r}: {reg!r}')
    return None, cyc


def at_prompt(reg):
    return bool(reg) and reg[-1].strip() == '$'


_TAG = [0]


def run_line(rig, line, label, failures, q=20_000, polls=900):
    """Type `line`, return (output rows, cycles to the prompt).  The
    line carries a trailing `#NN` comment that is unique on the glass,
    so the anchor can never be an earlier copy of the same command
    (`echo S$?` is typed a dozen times) whose output and prompt would
    satisfy the wait before the new line has even run."""
    _TAG[0] = (_TAG[0] + 1) % 100
    line = '%s #%d' % (line, _TAG[0])
    assert len(line) <= 38, f'{label}: {line!r} wraps the glass'
    anchor = '$ ' + line
    rig.type(line + '\r')
    reg, cyc = settle(rig, anchor, at_prompt, label, failures, polls, q)
    if reg is None:
        recover(rig)
        return None, cyc
    return reg[:-1], cyc


def recover(rig):
    for key in ('\x03', '\x04'):
        rig.type(key)
        try:
            D.wait_for_screen(rig.c, D.prompt_ready, 'recover',
                              max_steps=300)
            return
        except RuntimeError:
            continue


def fixture_lines(rig, lines, failures):
    for ln in lines:
        out, _ = run_line(rig, ln, 'fixture', failures)
        if out is None:
            return False
    return True


def cat_file(rig, name, failures, label):
    out, _ = run_line(rig, 'cat ' + name, label, failures)
    return out


# ---------------------------------------------------------------------
# R1 / R2: the burst under tail -f, over a sweep of start phases
# ---------------------------------------------------------------------
#: PHASE SWEEP.  tail -f polls once a second, and its schedule hangs
#: off the END of its last drain, so how long its first print of F
#: takes (the length of F's first line, printed char by char to the
#: glass) moves every later poll against the writer's burst; so does
#: how many `false` spawns the writer script makes before the burst,
#: and whether it sleeps 1 or 2 seconds.  Whether a writer's open lands
#: inside tail's hold is a property of those relations, so one fixed
#: phase may never collide (or always, until an unrelated change to the
#: kernel or sh moves the schedule: WAIT-1 did exactly that to a
#: hand-placed appender, and ORPHAN-1 thinned this sweep's hits from
#: 8-13 of 17 to 0-1 of 25 with the first-line knob alone -- hence the
#: grid).  The row walks the grid (sleep, spawns) x first-line length
#: and keeps going until MIN_SHIFTS shifts have run AND MIN_HITS of them
#: took a retry (the guest's own counter, OW_SEEN): a sweep that cannot
#: collide is a vacuous pass, so it FAILS at the end of the grid.
MIN_SHIFTS = 17         # WAIT-1's guest-side phase shifts
MIN_HITS = 3
LENGTHS = range(1, 26)  # 'echo ' + L + ' > F #NN' must fit 38 columns
GRID = [(1, 0), (1, 1), (2, 0), (2, 1), (1, 2), (2, 2), (1, 3), (2, 3)]
SHIFTS = [(sl, k, n) for (sl, k) in GRID for n in LENGTHS]


def build_burst(rig, op, shift, failures, label):
    sl, k, length = shift
    lines = ['echo %s > F' % ('a' * length),
             'echo "sleep %d" > APP' % sl]
    lines += ['echo false >> APP'] * k
    for i in range(1, SENTINELS + 1):
        body = 'x' if op == '>' else 'sentinel-%d' % i
        lines.append('echo "echo %s %s F" >> APP' % (body, op))
    # the guest's own barrier: printed (to the glass, by stderr) only
    # after the last open has succeeded or been refused
    lines.append('echo "echo %s >&2" >> APP' % END)
    return fixture_lines(rig, lines, failures)


#: OPEN-RW-2: `tail -f` declares READ intent now, so it joins a writer's
#: group and can no longer collide with it (the burst under `tail -f` is
#: rows R1t/R2t: every sentinel once, NO retry needed).  The transient
#: collision the sh retry exists for needs a NO-INTENT transient holder:
#: the poller script holds F open through `cksum F` once a second
#: (a write-capable, NO-INTENT open, like tail's old poll was), and
#: rows R1/R2 sweep a burst against it.
POLLER = 'POLL'


def build_poller(rig, failures):
    """The poller script: a NO-INTENT transient holder that does not
    truncate -- `cksum F` (it opens its operand with a plain count 3,
    census: none), run back to back like tail's old poll.  Unrolled:
    SH-EXECLOOP found that `for ... do exec ... done` never hung sh
    (`do CMD` was refused, notes sec 3) and sh takes that form now,
    but this poller needs no loop.  OAPPEND-1: the holder used to be
    `exec 3>>F`, which declares APPEND intent now and so no longer
    collides with a `>>` writer."""
    lines = ["echo 'cksum F' > P"]
    lines += ["echo 'cksum F' >> P"] * 29
    return fixture_lines(rig, lines, failures)


def burst_once(rig, op, idx, failures, poll=False):
    """One shift (SHIFTS[idx]).  Returns the largest retry count any
    sh showed, or None if the shift could not be run.  poll=False runs
    the burst under `tail -f F` (read intent: never collides);
    poll=True against a no-intent transient holder."""
    sl, k, length = SHIFTS[idx]
    tag = ('R1' if op == '>>' else 'R2') + ('' if poll else 't')
    label = f'{tag} sleep {sl} +{k} spawns, first line {length} chars'
    # the `#` tag makes this shift's echo unique on the glass, so
    # nothing an earlier shift printed can satisfy the wait below
    if poll:
        pipe = 'sh APP #%s%d' % (tag, idx)
    else:
        pipe = 'sh APP | tail -f F #%s%d' % (tag, idx)
    anchor = '$ ' + pipe
    if not build_burst(rig, op, SHIFTS[idx], failures, label):
        return None
    rig.clear_seen()
    if poll:
        if not build_poller(rig, failures):
            return None
        run_line(rig, 'sh P >/dev/null 2>&1 &', label, failures)
    rig.type(pipe + '\r')
    mx = 0

    def done(reg):
        # the guest's barrier is on the glass, below the command's echo
        return any(r == END for r in reg)

    # the poll also keeps the largest counter seen
    held, reg = None, None
    for _ in GR.polls(rig.c, 900, 50_000):
        mx = max([mx] + list(rig.seen().values()))
        reg = below(rig.rows(), anchor)
        if reg is not None and done(reg):
            if held == reg:
                break
            held = reg
        else:
            held = None
    else:
        failures.append(f'{label}: never saw {END!r} below the command; '
                        f'glass: {reg!r}')
        recover(rig)
        return None
    if poll:
        # the burst ends by itself: wait for its prompt, then for the
        # poller to run out, so the next shift starts from quiet
        try:
            D.wait_for_screen(rig.c, D.prompt_ready, label, max_steps=900)
        except RuntimeError as exc:
            failures.append(f'{label}: no prompt: {exc}')
            recover(rig)
            return None
        run_line(rig, 'wait', label, failures, q=100_000, polls=900)
    else:
        rig.type('\x03')
        try:
            D.wait_for_screen(rig.c, D.prompt_ready, label, max_steps=400)
        except RuntimeError as exc:
            failures.append(f'{label}: no prompt after ^C: {exc}')
            recover(rig)
            return None
    mx = max([mx] + list(rig.seen().values()))
    if 'sh: cannot redirect' in reg:
        failures.append(f'{label}: "sh: cannot redirect" on the glass '
                        f'-- the open was not retried')
    out = cat_file(rig, 'F', failures, label)
    if out is not None:
        want = (['a' * length] + ['sentinel-%d' % i
                                  for i in range(1, SENTINELS + 1)]
                if op == '>>' else ['x'])
        if out != want:
            failures.append(f'{label}: F is {out!r}, want {want!r} '
                            f'(each exactly once)')
    return mx


def burst_row(rig, op, failures, poll=True):
    """Walk SHIFTS until MIN_SHIFTS ran and (poll rows) MIN_HITS took a
    retry; the tail rows just run MIN_SHIFTS shifts."""
    hist = {}
    for idx in range(len(SHIFTS)):
        mx = burst_once(rig, op, idx, failures, poll)
        if mx is None:
            continue
        hist[SHIFTS[idx]] = mx
        hits = sum(1 for v in hist.values() if v)
        if len(hist) >= MIN_SHIFTS and (hits >= MIN_HITS or not poll):
            break
    return hist


# ---------------------------------------------------------------------
# R3 / R4 / R5
# ---------------------------------------------------------------------
def holder_fixture(rig, failures, label):
    # OPEN-RW-2: a long READER no longer blocks a writer (it joins), so
    # the long holder is now a WRITER: a second no-intent open of one
    # path is still $50
    # OAPPEND-1: `exec 3>>F` is an APPEND open now and a second `>>`
    # joins it; the long holder is a NO-INTENT writer (`>` is creat:
    # count 3), which refuses both `>>` and `>`
    return fixture_lines(rig, ['exec 3>F', 'echo a >&3'], failures)


def release(rig, failures):
    run_line(rig, 'exec 3>&-', 'cleanup', failures)


def row_bound(rig, op, failures):
    label = f'R3 exec 3>F; echo x {op} F'
    if not holder_fixture(rig, failures, label):
        return None
    rig.clear_seen()
    out, cyc = run_line(rig, f'echo x {op} F', label, failures, q=20_000)
    seen = max(rig.seen().values(), default=0)
    status, _ = run_line(rig, 'echo S$?', label, failures)
    release(rig, failures)
    after = cat_file(rig, 'F', failures, label)
    ok, _ = run_line(rig, 'echo alive', label, failures)
    if out != ['sh: cannot redirect']:
        failures.append(f'{label}: output {out!r}, want '
                        f'["sh: cannot redirect"]')
    if seen != OW_MAX:
        failures.append(f'{label}: retry counter {seen}, want the '
                        f'bound {OW_MAX}')
    lo, hi = OW_MAX * TICK, OW_MAX * 4 * TICK
    if not lo <= cyc <= hi:
        failures.append(f'{label}: refused after {cyc} cycles, want '
                        f'{lo}..{hi} (the bound)')
    if status != ['S1']:
        failures.append(f'{label}: status {status!r}, want S1')
    if after != ['a']:
        failures.append(f'{label}: F is {after!r}, want ["a"] -- a '
                        f'retried open must truncate/append nothing')
    if ok != ['alive']:
        failures.append(f'{label}: the shell is not usable after')
    print(f'[check-openrw] {label}: refused after ~{cyc} cycles, '
          f'{seen} retries, status {status}')
    return cyc


def row_interrupt(rig, failures):
    label = 'R4 ^C during the wait'
    if not holder_fixture(rig, failures, label):
        return None
    rig.clear_seen()
    anchor = '$ echo x >> F #R4'
    rig.type('echo x >> F #R4\r')
    # the guest raises the barrier: its own counter shows the shell is
    # in the wait (a few retries done, so it is asleep, not mid-open)
    for _ in GR.polls(rig.c, 400, 20_000):
        if max(rig.seen().values(), default=0) >= 3:
            break
    else:
        failures.append(f'{label}: the shell never started waiting')
        recover(rig)
        release(rig, failures)
        return None
    rig.type('\x03')
    cyc = 0
    reg = None
    for _ in GR.polls(rig.c, 600, 5_000):
        cyc += GR.quantum(5_000)
        reg = below(rig.rows(), anchor)
        if reg and at_prompt(reg):
            break
    else:
        failures.append(f'{label}: no prompt after ^C: {reg!r}')
        recover(rig)
        release(rig, failures)
        return None
    seen = max(rig.seen().values(), default=0)
    status, _ = run_line(rig, 'echo S$?', label, failures)
    release(rig, failures)
    after = cat_file(rig, 'F', failures, label)
    if 'sh: cannot redirect' in reg:
        failures.append(f'{label}: a ^C is not a refusal, but the shell '
                        f'said "cannot redirect": {reg!r}')
    if status != ['S130']:
        failures.append(f'{label}: status {status!r}, want S130')
    if cyc > 12 * TICK:
        failures.append(f'{label}: {cyc} cycles from ^C to the prompt, '
                        f'want <= {12 * TICK} (a few ticks, not the '
                        f'{OW_MAX * 2} the bound would take)')
    if seen >= OW_MAX:
        failures.append(f'{label}: the wait ran to the bound ({seen}); '
                        f'the ^C did not end it')
    if after != ['a']:
        failures.append(f'{label}: F is {after!r}, want ["a"]')
    print(f'[check-openrw] {label}: prompt {cyc} cycles after ^C, '
          f'status {status}, {seen} retries when it landed')
    return cyc


def row_other_errors(rig, failures):
    out_cyc = {}
    cases = [
        ('R5 >> into a missing directory', 'echo x >> /nodir/F'),
        ('R5 >  into a missing directory', 'echo x > /nodir/F'),
    ]
    for label, line in cases:
        rig.clear_seen()
        out, cyc = run_line(rig, line, label, failures, q=20_000)
        seen = max(rig.seen().values(), default=0)
        if out != ['sh: cannot redirect']:
            failures.append(f'{label}: output {out!r}')
        if seen:
            failures.append(f'{label}: retried {seen} time(s) -- only '
                            f'$50 is retried')
        if cyc > AT_ONCE:
            failures.append(f'{label}: refused after {cyc} cycles, want '
                            f'<= {AT_ONCE} (at once)')
        out_cyc[label] = cyc
        print(f'[check-openrw] {label}: refused after ~{cyc} cycles, '
              f'{seen} retries')
    # a write-locked target: `>` fails at the SET_EOF inside liba CREAT
    # (fd closed first), `>>` at the OPEN ($4E): neither is $50
    if fixture_lines(rig, ['echo a > L', 'chmod -dnw L'], failures):
        for label, line in (('R5 > a locked file', 'echo x > L'),):
            rig.clear_seen()
            out, cyc = run_line(rig, line, label, failures, q=20_000)
            seen = max(rig.seen().values(), default=0)
            if out != ['sh: cannot redirect']:
                failures.append(f'{label}: output {out!r}')
            if seen:
                failures.append(f'{label}: retried {seen} time(s)')
            if cyc > AT_ONCE:
                failures.append(f'{label}: refused after {cyc} cycles, '
                                f'want <= {AT_ONCE}')
            print(f'[check-openrw] {label}: refused after ~{cyc} '
                  f'cycles, {seen} retries')
        run_line(rig, 'chmod +dnw L', 'cleanup', [])
    return out_cyc


def boot(play, tmp):
    boot_po = os.path.join(tmp, 'play.po')
    shutil.copy(play, boot_po)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.call_tool('reset', {'backend': 'fast'})
    r = client.call_tool('mount_disk', {'path': boot_po, 'unit': 1})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk(unit 1) failed: {r}')
    for addr, val in ((D.PT_F40_ADDR, D.PT_F40_MAG1),
                      (D.PT_F40B_ADDR, D.PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                  'bank': 'main'})
    D.wait_for_screen(client, D.prompt_ready, 'shell prompt')
    return client


def fresh(play, syms, fn):
    """Boot a clean machine for one row group: a sweep's collisions
    depend on the guest's history (pids, tick phase), so every group
    starts from the same boot instead of inheriting its neighbour's."""
    tmp = tempfile.mkdtemp(prefix='maux-openrw-')
    try:
        client = boot(play, tmp)
        try:
            rig = Rig(client, syms)
            return fn(rig)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run(play, failures, only):
    syms = arena.symbol_table('sh')

    def want(tag):
        return not only or tag in only

    def refusals(rig):
        fixture_lines(rig, ['cd /tmp'], failures)
        if want('R3'):
            row_bound(rig, '>>', failures)
            row_bound(rig, '>', failures)
        if want('R4'):
            row_interrupt(rig, failures)
        if want('R5'):
            row_other_errors(rig, failures)

    if want('R3') or want('R4') or want('R5'):
        fresh(play, syms, refusals)

    def sweep(tag, op, poll):
        def go(rig):
            fixture_lines(rig, ['cd /tmp'], failures)
            hist = burst_row(rig, op, failures, poll)
            hits = sum(1 for v in hist.values() if v)
            worst = max(hist.values(), default=0)
            print(f'[check-openrw] {tag}: {len(hist)} shifts, {hits} '
                  f'took a retry, worst {worst} tries; hits at '
                  f'{[k for k, v in hist.items() if v]}')
            if not poll:
                if hits:
                    failures.append(
                        f'{tag}: {hits} shift(s) needed a retry under '
                        f'`tail -f`, which declares read intent and so '
                        f'joins a writer instead of colliding with it')
            elif hits < MIN_HITS:
                failures.append(
                    f'{tag}: only {hits} of {len(hist)} shifts took a '
                    f'retry (want {MIN_HITS}) -- a sweep that cannot '
                    f'collide proves nothing')
        return go

    for tag, op, poll in (('R1', '>>', True), ('R2', '>', True),
                          ('R1t', '>>', False), ('R2t', '>', False)):
        if want(tag):
            fresh(play, syms, sweep(tag, op, poll))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('rows', nargs='*', help='R1 R2 R1t R2t R3..R5 (default all)')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-openrw: {play} missing -- make play-image')
        return 2
    failures = []
    t0 = time.time()
    try:
        run(play, failures, set(args.rows))
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-openrw] FAIL: {len(failures)} problem(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-openrw] PASS: > and >> wait out a busy open '
          f'({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
