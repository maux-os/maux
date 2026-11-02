#!/usr/bin/env python3
"""e2e_term.py -- a PERSON-LIKE terminal driver for maux e2e tests.

The older harnesses (check_vi, check_jobctl_*) drive the emulator the way
no human does: `type` a whole string in one burst, then `step` a big
fixed slice, then read the glass. That serialises the
input -> cook -> echo -> scheduler -> render pipeline (all keys land in
the latch before the CPU runs any) and steps deterministically, so it
hides real-time races AND can register a key the guest never echoed.
Both produced false positives this project actually shipped: a ^Z that
left the shell with no echo, and a nesting wedge -- neither caught.

This driver instead operates the machine like a person:

  * ONE key at a time. press() injects a single key, then lets the guest
    FREE-RUN a realistic, JITTERED slice so it fully consumes and echoes
    that key -- and so the NEXT key lands at a varying point in the CPU's
    work, which is what samples timing-dependent races.
  * OBSERVE THE GLASS, not a step count. wait() polls what is actually
    rendered (screen_text for 40/80-col, ultraterm_state for the card)
    until the expected text appears or a real timeout elapses.
  * ASSERT WHAT A PERSON SEES. Echo especially: a typed command is only
    "there" if the guest echoed it -- the `type` tool does not fake echo
    (proven: a no-echo shell renders `$ CMD`'s OUTPUT but not the typed
    `CMD`), so a row holding the typed text is a true echo oracle.

Backends: 'text40' (40-col -- HONEST since task #23 deliverable C: boot()
pokes the PT_F40 magic, pt_f40.py, the same knob check_play.py uses,
right after `reset` and before `mount_disk`, so the play image actually
boots 40 columns instead of its native-80 default), 'text80' (native-80
via `vidmode 80`), 'ut' (the UltraTerm card). One suite runs on each.
"""
import os
import random
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402
import gate_race as GR                                   # noqa: E402
from pt_f40 import (PT_F40_ADDR, PT_F40B_ADDR,           # noqa: E402
                    PT_F40_MAG1, PT_F40_MAG2)

DISK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    'build', 'play.po')

# A human keystroke gap is ~50-200 ms; at ~1 MHz that is ~50k-200k CPU
# cycles. Jitter it so successive keys land at varying CPU offsets --
# the whole point of a race hunt. A GATE run pins the seed for
# reproducibility; a --hunt run varies it to sample more interleavings.
KEY_CYC_MIN = 40_000
KEY_CYC_MAX = 160_000


class Wedged(Exception):
    """The guest stopped responding to input (no echo / no screen change
    within the person-scale timeout) -- a real hang, not a slow one."""


class Term:
    def __init__(self, c, backend='text40', seed=1234, verbose=False):
        self.c = c
        self.backend = backend
        self.rng = random.Random(seed)
        self.verbose = verbose

    # -- observation -------------------------------------------------
    def screen(self):
        if self.backend == 'ut':
            st = self.c.call_tool('ultraterm_state', {})
            return st.get('text') or [] if st.get('installed') else []
        r = self.c.call_tool('screen_text', {})
        return r.get('merged') or r.get('main') or []

    def visible(self, substr):
        return any(substr in row for row in self.screen())

    def dump(self, tag):
        print(f'--- {tag} [{self.backend}] ---')
        for i, row in enumerate(self.screen()):
            if row.strip():
                print(f'{i:2}|{row.rstrip()}')
        sys.stdout.flush()

    # -- run the guest a realistic, jittered slice -------------------
    def _slice(self, cyc=None):
        self.c.call_tool('step', {'cycles': cyc or
                                  self.rng.randint(KEY_CYC_MIN, KEY_CYC_MAX)})

    def _poll(self):
        """One slice of a wait loop. Outside `early` it IS _slice(), so
        a subclass that overrides _slice (demo_record.RecTerm turns every
        slice into whole video frames) sees the same calls and the same
        rng draws as before GATE-RACE-1. In `early` the slice is finer
        (gate_race.py) and the loops get more of them."""
        if GR.MODE != 'early':
            self._slice()
            return
        cyc = self.rng.randint(KEY_CYC_MIN, KEY_CYC_MAX)
        self.c.call_tool('step', {'cycles': GR.quantum(cyc)})
        GR._stats['fine_polls'] += 1

    # -- input, one key at a time -----------------------------------
    def press(self, key, cyc=None):
        """Inject ONE key (a char, or a raw \\xHH escape), then free-run a
        realistic slice so the guest consumes and echoes it."""
        self.c.call_tool('type', {'text': key})
        self._slice(cyc)

    def type_human(self, s):
        """Type each character of `s` as a separate keystroke, the way a
        person does -- NOT a burst into the latch."""
        for ch in s:
            self.press(ch)

    def enter(self):
        self.press('\r')

    ESC = '\x1b'
    CTRL_C = '\x03'
    CTRL_Z = '\x1a'
    CTRL_D = '\x04'

    # -- waiting on the glass ----------------------------------------
    def wait(self, substr, label, timeout_slices=40):
        """Poll the rendered glass until `substr` appears. Person-scale:
        a real terminal shows a prompt/echo in well under a second. If it
        never appears, that is a Wedged/failed condition, reported with
        the screen."""
        for _ in range(GR.count(timeout_slices, KEY_CYC_MAX)):
            if self.visible(substr):
                return
            self._poll()
        raise Wedged(f'{label}: never saw {substr!r}; screen:\n' +
                     '\n'.join(r.rstrip() for r in self.screen() if r.strip()))

    def wait_prompt(self, label, timeout_slices=60):
        """Wait until the shell prompt is BACK and SETTLED -- the last
        non-blank row, stripped, is a `$` prompt (tolerating the `$ $` a
        ^Z leaves) AND unchanged across two polls (no output still
        streaming). A person waits to SEE the prompt before typing;
        typing into mid-output races the echo against that output."""
        pat = re.compile(r'\$( \$)*$')
        stable = 0
        last = None
        for _ in range(GR.count(timeout_slices, KEY_CYC_MAX)):
            nb = [r for r in self.screen() if r.strip()]
            cur = nb[-1].strip() if nb else ''
            if pat.fullmatch(cur) and cur == last:
                stable += 1
                if stable >= 2:
                    return
            else:
                stable = 0
            last = cur
            self._poll()
        raise Wedged(f'{label}: prompt never settled; screen:\n' +
                     '\n'.join(r.rstrip() for r in self.screen() if r.strip()))

    def wait_gone(self, substr, label, timeout_slices=40):
        for _ in range(GR.count(timeout_slices, KEY_CYC_MAX)):
            if not self.visible(substr):
                return
            self._poll()
        raise Wedged(f'{label}: {substr!r} never cleared; screen:\n' +
                     '\n'.join(r.rstrip() for r in self.screen() if r.strip()))

    # -- person-visible assertions -----------------------------------
    def type_and_expect_echo(self, s, label):
        """Type `s` char-by-char and require the terminal to ECHO it (the
        typed text becomes visible). This is the check the old harness
        never made after a ^Z, and the reason the dead-echo bug shipped."""
        self.type_human(s)
        self._slice()
        if not self.visible(s):
            raise AssertionError(
                f'{label}: typed {s!r} but it did NOT echo -- the terminal '
                f'is not in cooked+echo:\n' +
                '\n'.join(r.rstrip() for r in self.screen() if r.strip()))

    def run_cmd_echoed(self, cmd, label):
        """Wait for a settled prompt (a person does), then type a shell
        command (which must echo), Enter, and let it run."""
        self.wait_prompt(label + ' (prompt ready)')
        self.type_and_expect_echo(cmd, label)
        self.enter()
        self._slice()

    # -- replay a recorded live session -----------------------------
    def replay(self, klog_path, cap_slice=3_000_000):
        """Replay a keylog recorded by `make play-rec`
        (VERILOGAPPLE_KEYLOG lines: '<cycle> <hexbyte>') FAITHFULLY:
        step each recorded inter-key cycle gap, then inject that raw
        byte -- a deterministic re-run of a real person's session, at
        the timing they actually used. A long idle gap is capped so a
        coffee break does not stall the test. Returns the key count."""
        prev = None
        n = 0
        with open(klog_path) as f:
            for line in f:
                parts = line.split()
                if len(parts) != 2:
                    continue
                cyc, b = int(parts[0]), int(parts[1], 16)
                if prev is not None:
                    self._slice(max(1_000, min(cyc - prev, cap_slice)))
                self.c.call_tool('type', {'text': '\\x%02x' % b})
                prev = cyc
                n += 1
        self._slice(500_000)          # let the last key settle
        return n


def boot(c, backend, reset_extra=None):
    """Reset the right hardware, mount play.po, wait for the shell.

    reset_extra: optional dict merged into the `reset` call's args (e.g.
    {'ssc': True, 'clock': False} for a serial-line gate) -- an addition,
    not a copy of this function: check_tip.py's own boot needs the SSC
    installed and the Timemaster clock (slot 2, same as the SSC default)
    freed, everything else about booting the play image is identical."""
    c.require_tools('screen_text')
    if backend == 'ut':
        c.require_tools('ultraterm_state')
        args = {'backend': 'fast', 'aux': 'ramworks', 'ultraterm': True}
        if reset_extra:
            args.update(reset_extra)
        r = c.call_tool('reset', args)
        if not r.get('ok') or not r.get('ultraterm'):
            raise RuntimeError(f'reset ultraterm failed: {r}')
    else:
        args = {'backend': 'fast', 'aux': 'ramworks'}
        if reset_extra:
            args.update(reset_extra)
        c.call_tool('reset', args)
    if backend == 'text40':
        # Force the 40-column boot (src/test/playtestb.s PT_F40, via
        # pt_f40.py) -- MUST land here, after `reset` and before
        # `mount_disk`/any stepping: ENTRY checks it before PRC_INIT
        # ever reads TTY_BKND_REQ (check_play.py's own PT_HOLD/PT_F40
        # ordering comment has the full argument). Without this the
        # 'text40' label boots the play image's native-80 default and
        # this whole backend silently exercises N8 twice (docs/
        # CONSOLE-VT102.md sec 7, task #23 deliverable C).
        c.call_tool('poke', {'addr': PT_F40_ADDR, 'bytes': [PT_F40_MAG1],
                             'bank': 'main'})
        c.call_tool('poke', {'addr': PT_F40B_ADDR, 'bytes': [PT_F40_MAG2],
                             'bank': 'main'})
    c.call_tool('mount_disk', {'path': DISK, 'unit': 1, 'copy': True})
    t = Term(c, backend)
    t.wait('$', 'boot: shell prompt', timeout_slices=120)
    if backend == 'text80':
        t.run_cmd_echoed('vidmode 80', 'boot: vidmode 80')
        t.wait('$', 'boot: prompt after vidmode 80')
    return t


def session(backend, run, seed=1234, reset_extra=None):
    """Boot `backend`, run `run(term)`, tidy up. Returns (ok, error)."""
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        t = boot(c, backend, reset_extra=reset_extra)
        t.rng.seed(seed)
        run(t)
        return True, None
    except (AssertionError, Wedged) as e:
        return False, e
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
