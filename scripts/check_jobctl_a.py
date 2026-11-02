#!/usr/bin/env python3
"""check_jobctl_a.py -- per-console FOREGROUND targeting for ^C
(`make check-jobctl-a`, in check-all-cross). docs/JOB-CONTROL.md,
Increment A.

Before this increment ^C was machine-GLOBAL: TTY_INTR set a bare flag
and PRC_INTR_SWP killed EVERY live process at spawn depth >= 3 -- the
foreground pipeline, yes, but also every `&` job on the console and
every other console's foreground job. Now the shell DECLARES its
console's foreground job (SYS_TCSETFG: the live stage pids, cleared at
the prompt), the tty records WHICH console typed the ^C, and the sweep
kills that console's declared set -- its live pids and their
descendants -- and nothing else.

Cases, each against the REAL kernel + shell on the fast backend, all
asserted on the annex PCB table (state UNUSED/RUNNABLE/RUNNING/BLOCKED/
ZOMBIE, mm.annex2.equ) and on the glass:

  bg_survives   `sleep 200 &` (a polling, never-exiting job), then a
                FOREGROUND `sleep 200`, then ^C: the foreground sleep is
                DEAD (reaped -- its slot is UNUSED) and the background
                sleep is STILL ALIVE. The live-pid set after ^C equals
                the set before the foreground command ran.
  script_whole  the same background job present, then `sh JCS` where JCS
                is `sleep 200`: ^C kills the script sh AND its sleep (the
                job is the declared pid's whole subtree -- a non-
                interactive sh declares nothing, its children are reached
                as descendants), and the background sleep still lives.
  idle_prompt   ^C at the idle prompt (empty foreground set) kills
                nothing: the shell reprompts, `echo IDLEOK` runs, and the
                background sleep still lives.
  orphan_zombie a PCB-slot-leak regression (2026-09-14 probe evidence:
                the killer subshell of a vi `:!( sleep 3 ; kill N ) &`
                stayed state 04 forever). `sh JCZOMB` (JCZOMB =
                `( sleep 1 ) &`) runs to completion almost at once: it
                spawns X (the script sh), X backgrounds the sleep
                subshell Y and exits. ORPHAN-1: Y is ADOPTED BY INIT at
                X's death -- the stop right after X's PRC_ADOPT, before
                any reaper, reads Y's parent as 1 in the annex and the
                shadow -- and ~1s later, when Y exits, INIT (not the
                login shell, not an orphan sweep) reaps it. Asserts Y is
                alive with PPID 1 when the prompt returns, and that its
                slot reaches UNUSED by a PRC_REAP_ONE called with
                K_CURPID 1. (Until 2026-10-22 the reap was
                PRC_REAP_ORPH's, an eventual UNUSED with no stop.)
  shell_kill    (RULINGS-1, 2026-10-18: rows a and b) `kill -9 $$` and
                `kill $$` at the console. The shell dies and init
                respawns it: a fresh prompt on the same console, a
                FRESH shell (a variable set before the kill is gone),
                the console cooked + echo, and a typed command echoes
                and runs. Replaces the 2026-09-14 case
                `shell_protected`, which asserted the opposite
                contract (the kill REFUSED, `kill: N: cannot kill`,
                shell untouched, because no init existed to respawn
                it). A ruled contract change, so a rewritten row and
                not a removed oracle -- old and new side by side in
                docs/RULINGS-1-NOTES.md. `kill -0 $$` (the probe) is
                unaffected and is kept as the last step of this case.
  shell_orphan  (row c) with `sleep 20 &` running, `kill -9 $$`. The
                orphan is NOT killed (V7: an `&` job survives its
                shell); ORPHAN-1 reparents it to INIT at the shell's
                death (V7 sys1.c exit(), 4.2BSD kern_exit.c), so the
                respawn landing in the dead shell's slot (same pid)
                adopts nothing. Until 2026-10-22 it was "adopted by
                SLOT IDENTITY" -- the job's PCB_PARENT named the new
                shell. Asserted: right after the respawn the job's
                parent is 1; every non-free PCB is pid 1, pid 2, the
                new shell, or init's job; the job ends and INIT reaps
                it with no command typed (a PRC_REAP_ONE called with
                K_CURPID 1, never the shell); `true` in the new shell
                prints nothing (no notice for a job it never ran); the
                table is then exactly {1, 2, shell}, no ZOMBIE, and the
                BANK LEDGER (free list + lazy-free HELD tags + banks
                named by a live PCB, read from the kernel's own cells)
                equals its value before the job existed.
  shell_raw     (row d) `stty raw`, then `kill -9 $$`: the successor's
                console is cooked + echo (VC_TMODE), not raw. NOTE the
                kernel's PRC_TMD_RST backstop does NOT cover this
                row -- it resets only a victim in the console's
                foreground set, and the shell, blocked in the `kill`
                it runs, has declared that command's pids, not itself
                (it IS in the set, as a SELF set, while its line
                editor owns the prompt: check-shedit `kill9` is that
                case) -- so the restore that makes this row pass is the
                interactive shell's own start-up stamp (shlex.s), the
                getty rule (learning:01M284K7XBS7CYRQH2NJ9J1WE5 warns
                about exactly this false attribution).
  shell_flap    (row e) six `kill -9 $$` in a row: init's rate limit
                backs off (one console line, no shell for the
                back-off) and then respawns a working shell -- never
                parks (KFIX7's contract, driven through kill instead
                of exit).

Teeth (measured on d52920d, the tree without the feature): ALL THREE go
RED -- the global depth sweep kills the background sleep on every ^C,
the idle-prompt one included (live set [1,2,3,4] -> [1,2,3] with nothing
in the foreground). idle_prompt also guards TTY_INTR's empty-line
reprompt, which is unchanged.

orphan_zombie's teeth (ORPHAN-1): skipping the annex write in PRC_ADOPT
(or moving the adoption into PRC_REAP_ONE) sends it RED at the stop of
row 3 (Y still names the dead script sh); see scripts/teeth_orphan.py.
(The 2026-09-14 tooth, PRC_REAP_ORPH's ZOMBIE branch, died with the
routine.)

shell_kill / shell_orphan / shell_raw / shell_flap teeth
(RULINGS-1): with PRC_KILL's console-shell refusal restored every one
goes RED -- nothing dies, so the marker survives, the orphan's shell is
the old shell, the console stays raw, and init never sees a death to
back off from. Further sabotages in docs/RULINGS-1-NOTES.md.

The foreground-set wait: the shell declares the job AFTER spawning it,
so this gate waits until VC_FGJOB[console 0] names the new pid before
typing ^C -- otherwise it would type into the spawn window CONSOLE.md
sec 4 documents (a ^C with nothing yet to kill). On a tree without the
table the wait times out and the ^C is typed anyway (the depth sweep
needs no declaration), which is what makes the RED measurable rather
than a hang.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_race as GR                                  # noqa: E402
import check_vi as V                                    # noqa: E402
import check_init as CI                                 # noqa: E402
import check_jobctl_b as JB                             # noqa: E402
import wait_orphan as WO                                # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# inc/mm.annex*.equ -- the PCB array and the foreground table.
PCB_ARRY_ADDR = 0x0800
PCB_ENT_SIZE = 16
PCB_COUNT = 48
PCB_STATE = 1
PCB_PARENT = 4
PCB_EXITSTAT = 6
ST_UNUSED, ST_RUNNABLE, ST_RUNNING, ST_BLOCKED, ST_ZOMBIE = 0, 1, 2, 3, 4
ST_NAME = {0: 'UNUSED', 1: 'RUNNABLE', 2: 'RUNNING', 3: 'BLOCKED',
           4: 'ZOMBIE', 5: 'STOPPED'}
VC_FGJOB_ADDR = 0x7680
VC_FGJ_STRIDE = 4

BG_CMD = 'sleep 200 &'
FG_CMD = 'sleep 200'
JCZOMB_CMD = '( sleep 1 ) &'


def at_prompt1(rs):
    """STRICTLY one prompt: the last non-blank row is exactly `$`.
    at_prompt() accepts `$ $` (the doubled prompt a ^C leaves); a
    row that says `$ $` after a TERM would be a second, unwanted
    prompt (H4)."""
    nb = [r.strip() for r in rs if r.strip()]
    return bool(nb) and nb[-1] == '$'


def at_prompt(rs):
    """The last non-blank row is a prompt. After a ^C it reads `$ $`:
    the shell reprompts once for the reaped child and once more for
    the EMPTY line TTY_INTR completes (docs/CONSOLE.md sec 4) -- the
    same doubled prompt the tree showed before this increment."""
    nb = [r for r in rs if r.strip()]
    return bool(nb) and re.fullmatch(r'\$( \$)*', nb[-1].strip()) is not None


def peek_annex(c, addr, n):
    r = c.call_tool('peek', {'addr': addr, 'count': n, 'bank': 'aux',
                             'aux_bank': 0})
    return r.get('bytes') or r.get('data')


def pcb_states(c):
    tbl = peek_annex(c, PCB_ARRY_ADDR, PCB_COUNT * PCB_ENT_SIZE)
    out = {}
    for pid in range(1, PCB_COUNT):
        e = tbl[pid * PCB_ENT_SIZE:(pid + 1) * PCB_ENT_SIZE]
        out[pid] = (e[PCB_STATE], e[PCB_PARENT])
    return out


def live_pids(c):
    """pids whose slot is RUNNABLE/RUNNING/BLOCKED -- a zombie is dead."""
    return {pid for pid, (st, _) in pcb_states(c).items()
            if st in (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED)}


def fgset(c, console=0):
    row = peek_annex(c, VC_FGJOB_ADDR + console * VC_FGJ_STRIDE,
                     VC_FGJ_STRIDE)
    return row[0] & 0x7F, [p for p in row[1:] if p]   # bit 7: SELF


def step(c, n=1):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def ctrl_c(c):
    # check_play's own idiom: the inject decodes the escape.
    c.call_tool('type', {'text': '\\x03'})
    step(c, 4)


def settle_pids(c, pred, label, max_steps=600):
    for _ in GR.polls(c, max_steps):
        pids = live_pids(c)
        if pred(pids):
            return pids
    raise AssertionError(f'timed out waiting for {label}; live pids '
                         f'{sorted(live_pids(c))}, screen:\n'
                         + '\n'.join(V.rows(c)))


def wait_declared(c, want, label, max_steps=300):
    """Until VC_FGJOB[0] names every pid in `want`. Returns True, or
    False after the bound (a tree with no table never gets there)."""
    for _ in GR.polls(c, max_steps):
        _, pids = fgset(c)
        if want <= set(pids):
            return True
    print(f'[check-jobctl-a] {label}: foreground set never named '
          f'{sorted(want)} (fgset={fgset(c)}) -- typing ^C anyway',
          flush=True)
    return False


def describe(c, pids):
    st = pcb_states(c)
    return ', '.join(f'{p}:{ST_NAME.get(st[p][0], st[p][0])}'
                     for p in sorted(pids))


def start_bg(c):
    """`sleep 200 &` -> the one new live pid, the prompt back."""
    before = live_pids(c)
    V.t(c, BG_CMD + '\r')
    pids = settle_pids(c, lambda s: len(s - before) == 1 and
                       at_prompt(V.rows(c)),
                       'background sleep spawned and prompt back')
    bg = (pids - before).pop()
    print(f'[check-jobctl-a] background sleep is pid {bg} '
          f'({describe(c, {bg})})', flush=True)
    return bg


def run_fg_and_interrupt(c, cmd, label, expect_new):
    """Run `cmd` foreground, wait for `expect_new` new live pids, wait
    for the declaration, ^C, wait for the prompt. Returns (base set,
    the new pids)."""
    base = live_pids(c)
    V.t(c, cmd + '\r')
    pids = settle_pids(c, lambda s: len(s - base) == expect_new,
                       f'{label}: {expect_new} new process(es) for '
                       f'`{cmd}`')
    new = pids - base
    # the shell declares its DIRECT children -- a script's own child is
    # reached as a descendant, so only the direct child is awaited
    direct = {p for p in new if pcb_states(c)[p][1] not in new}
    wait_declared(c, direct, label)
    print(f'[check-jobctl-a] {label}: foreground `{cmd}` = pids '
          f'{sorted(new)} (declared {fgset(c)}); typing ^C', flush=True)
    ctrl_c(c)
    V.settle(c, lambda rs: any('^C' in r for r in rs) and at_prompt(rs),
             f'{label}: ^C echoed and the prompt back')
    return base, new, direct


def assert_after(c, base, new, direct, bg, label):
    """After ^C: the new pids are dead and the live set is exactly what
    it was before the foreground command -- the background job
    included. The shell's DIRECT child must be reaped (UNUSED); a
    grandchild may be left ZOMBIE -- its parent died in the same sweep
    and maux has no init to adopt orphans (sc.proc.equ's SYS_KILL
    note; the old depth sweep left the same zombie)."""
    pids = settle_pids(c, lambda s: s == base, f'{label}: live set back '
                       f'to the pre-command set {sorted(base)}',
                       max_steps=200)
    st = pcb_states(c)
    for p in sorted(new):
        want = (ST_UNUSED,) if p in direct else (ST_UNUSED, ST_ZOMBIE)
        if st[p][0] not in want:
            raise AssertionError(f'{label}: foreground pid {p} is '
                                 f'{ST_NAME.get(st[p][0])} after ^C -- '
                                 f'killed but never reaped, or not killed')
    if bg not in pids:
        raise AssertionError(f'{label}: the BACKGROUND sleep (pid {bg}) '
                             f'did not survive ^C -- it is '
                             f'{ST_NAME.get(st[bg][0])}; the sweep is '
                             f'still global')
    print(f'[check-jobctl-a] {label}: after ^C live = {describe(c, pids)}; '
          f'foreground {sorted(new)} reaped, background {bg} alive',
          flush=True)


def echo_ok(c, word, label):
    V.t(c, f'echo {word}\r')
    V.settle(c, lambda rs: any(r.strip() == word for r in rs)
             and at_prompt(rs), f'{label}: `echo {word}` ran')


# --------------------------------------------------------------------
def case_bg_survives(c):
    bg = start_bg(c)
    base, new, direct = run_fg_and_interrupt(c, FG_CMD, "bg_survives", 1)
    assert_after(c, base, new, direct, bg, "bg_survives")
    echo_ok(c, 'FGOK', 'bg_survives')
    return bg


def case_script_whole(c, bg):
    V.t(c, 'echo sleep 200 > JCS\r')
    V.settle(c, at_prompt, 'script_whole: JCS written')
    base, new, direct = run_fg_and_interrupt(c, "sh JCS", "script_whole", 2)
    assert_after(c, base, new, direct, bg, "script_whole")
    echo_ok(c, 'SCRIPTOK', 'script_whole')


def case_idle_prompt(c, bg):
    base = live_pids(c)
    # While sh reads its prompt it declares ITSELF foreground (SYS_TCSETFG
    # {1, self}, TAB-A2) so ^C/^Z reach it as signals; that is not a job.
    # No JOB may be in the set.
    cnt, pids = fgset(c)
    if [p for p in pids if p != shell_pid(c)]:
        raise AssertionError(f'idle_prompt: a job is in the foreground '
                             f'set at the prompt: {fgset(c)}')
    ctrl_c(c)
    V.settle(c, lambda rs: any('^C' in r for r in rs) and at_prompt(rs),
             'idle_prompt: ^C echoed and the prompt back')
    echo_ok(c, 'IDLEOK', 'idle_prompt')
    pids = live_pids(c)
    if pids != base:
        raise AssertionError(f'idle_prompt: ^C at the prompt changed the '
                             f'live set {sorted(base)} -> {sorted(pids)}')
    if bg not in pids:
        raise AssertionError(f'idle_prompt: the background sleep (pid '
                             f'{bg}) died to an idle-prompt ^C')
    print(f'[check-jobctl-a] idle_prompt: live = {describe(c, pids)}',
          flush=True)


def case_orphan_zombie(c):
    """ORPHAN-1: the script sh X backgrounds Y and exits; Y is adopted
    by init at X's death (the stop after PRC_ADOPT, before any reaper)
    and init reaps Y when it exits."""
    before = live_pids(c)
    V.settle(c, at_prompt, 'orphan_zombie: shell prompt')
    V.t(c, f"echo '{JCZOMB_CMD}' > JCZOMB\r")
    V.settle(c, at_prompt, 'orphan_zombie: JCZOMB written')
    watch = WO.AdoptWatch(c, ROOT)
    try:
        V.t(c, 'sh JCZOMB\r')
        for _ in range(GR.count(600)):
            watch.run(GR.quantum())
            pids = live_pids(c)
            if len(pids - before) == 1 and at_prompt(V.rows(c)):
                break
        else:
            raise AssertionError('orphan_zombie: the backgrounded sleep '
                                 'subshell never stood alone with the '
                                 'prompt back; ' + machine_state(c))
        y = (pids - before).pop()
        ySt, yPar = pcb_states(c)[y]
        if ySt == ST_UNUSED or yPar != 1:
            raise AssertionError(f'orphan_zombie: pid {y} is '
                                 f'{ST_NAME.get(ySt, ySt)} with parent '
                                 f'{yPar}; wanted ALIVE under init '
                                 '(parent 1)')
        mine = [w for w in watch.windows if y in w['orph']]
        if len(mine) != 1:
            raise AssertionError(f'orphan_zombie: pid {y} was an orphan '
                                 f'in {len(mine)} adoption windows, '
                                 'wanted exactly one')
        w = mine[0]
        if w['post'][y]['parent'] != 1 or w['post'][y]['shd'] != 1 or \
                w['reaped_inside']:
            raise AssertionError(
                f'orphan_zombie: at the stop after PRC_ADOPT ({w["route"]}) '
                f'pid {y} reads parent {w["post"][y]["parent"]} / shadow '
                f'{w["post"][y]["shd"]}, {w["reaped_inside"]} reap(s) '
                'inside -- adoption did not happen AT DEATH')
        print(f'[check-jobctl-a] orphan_zombie: sleep subshell is pid {y} '
              f'({ST_NAME.get(ySt, ySt)}); at X\'s death (route '
              f'{w["route"]}) it read parent {w["pre"][y]["parent"]} '
              f'-> 1 in annex and shadow, before any reaper', flush=True)
        for _ in range(GR.count(300)):
            watch.run(GR.quantum())
            if pcb_states(c)[y][0] == ST_UNUSED:
                break
        else:
            st = pcb_states(c)[y][0]
            raise AssertionError(f'orphan_zombie: pid {y} never reaped -- '
                                 f'stuck at {ST_NAME.get(st, st)}. '
                                 + machine_state(c))
        who = [r for p, r in watch.reaps if p == y]
        if who != [1]:
            raise AssertionError(f'orphan_zombie: pid {y} was reaped by '
                                 f'{who}, wanted init (1)')
    finally:
        watch.close()
    echo_ok(c, 'ZOMBOK', 'orphan_zombie')
    print(f'[check-jobctl-a] orphan_zombie: pid {y} exited and was reaped '
          'by init (UNUSED)', flush=True)


def machine_state(c):
    """Is the PCB leaking, or is the MACHINE dead? Ask before blaming
    the process.

    Added 2026-09-20, because this gate said "its PCB slot leaked
    forever" while the truth was that the kernel had taken a BRK and
    parked in KRN_BRK_TRAP (src/kernel/entry2.s) with interrupts
    masked: no tick, no preemption, nothing would ever change in ANY
    slot. A sibling sat RUNNABLE for the whole 30M-cycle wait and the
    message pointed at the wrong subsystem.

    The signature is build-independent on purpose -- K_BRK_MARKER's
    address moves with every kernel build, so this does NOT peek it.
    A PC that stays inside one instruction while I is SET is a halt;
    A = $42 on top of that is KRN_BRK_TRAP's own marker value, which
    it loads immediately before its `jmp *`.

    SINCE KBRK (docs/KBRK.md) THAT HALT IS NO LONGER WHAT A USER BRK
    DOES: a user process that takes a BRK (the wild jump / corrupted
    return this note was written for) dies of SIGTRAP, exit status
    $85, and the machine runs on -- so the halt signature now means a
    BRK in a ROOT-TIER process (pid 1, idle) or, with A=$10, in the
    kernel (MAIN_IRQ_SHIM's park). The user case is reported from the
    PCB table instead: a ZOMBIE slot holding $85."""
    seen = []
    for _ in range(4):
        step(c)
        seen.append(c.call_tool('regs', {}))
    pcs = [r.get('pc', -1) for r in seen]
    masked = all(r.get('p', 0) & 0x04 for r in seen)
    if max(pcs) - min(pcs) <= 3 and masked:
        acc = seen[-1].get('a')
        brk = ' -- A=$42 is KRN_BRK_TRAP\'s marker, so the kernel took ' \
              'a BRK (a wild jump or a corrupted return), not a reap ' \
              'failure' if acc == 0x42 else ''
        return (f'THE MACHINE IS HALTED, not the reaper: PC parked at '
                f'${min(pcs):04X} with interrupts MASKED and A=${acc:02X}'
                f'{brk}. Live slots: {pcb_states_str(c)}')
    tbl = peek_annex(c, PCB_ARRY_ADDR, PCB_COUNT * PCB_ENT_SIZE)
    trapped = [pid for pid in range(1, PCB_COUNT)
               if tbl[pid * PCB_ENT_SIZE + PCB_STATE] == 4
               and tbl[pid * PCB_ENT_SIZE + PCB_EXITSTAT] == 0x85]
    if trapped:
        return (f'the machine is still running, but pid(s) {trapped} died '
                f'of SIGTRAP (exit $85): a BRK in USER code -- a wild jump '
                f'or a corrupted return, not a reap failure. Live slots: '
                f'{pcb_states_str(c)}')
    return (f'the machine is still running (PC {pcs}), so this is the '
            f'reap path. Live slots: {pcb_states_str(c)}')


def pcb_states_str(c):
    return ', '.join(f'{p}:{ST_NAME.get(st, st)}(parent {par})'
                     for p, (st, par) in sorted(pcb_states(c).items())
                     if st)

def shell_pid(c):
    """The interactive shell's pid: the one live pid whose PARENT is
    itself a direct child of root tier (PCB_PARENT 0) -- i.e. a
    grandchild of nothing. Robust to how many other processes earlier
    cases spawned/reaped: in this boot topology only the interactive
    shell is ever a grandchild of the root."""
    st = pcb_states(c)
    for pid, (state, parent) in st.items():
        if state == ST_UNUSED or parent == 0:
            continue
        if st.get(parent, (None, None))[1] == 0:
            return pid
    raise AssertionError('no pid is a grandchild of root tier -- '
                         f'cannot find the shell; pcb={st}')


def cmd_output(rows, cmd):
    """The rows a JUST-typed `cmd` printed, scoped between its own
    echoed `$ cmd` line and the prompt that follows -- the 24-line
    glass keeps no scrollback, so an older command's still-visible
    output (e.g. the PRIOR kill's own `cannot kill` line, still on
    screen one command later) is not mistaken for THIS command's
    output. Returns [] if `cmd` printed nothing, or was not found
    echoed at all."""
    echoed = f'$ {cmd}'
    idx = None
    for i, r in enumerate(rows):
        if r.rstrip() == echoed:
            idx = i
    if idx is None:
        return []
    nb = [r for r in rows[idx + 1:] if r.strip()]
    while nb and re.fullmatch(r'\$( \$)*', nb[-1].strip()):
        nb.pop()
    return nb


def last_status(c, label, max_steps=300):
    """`echo $?`, then the digits row immediately before the next
    prompt -- the standard one-line-of-output-then-prompt shape every
    other case in this file already relies on."""
    V.t(c, 'echo $?\r')
    rows = V.settle(c, at_prompt, f'{label}: `$?` printed',
                    max_steps=max_steps)
    nb = [r.strip() for r in rows if r.strip()]
    if len(nb) < 2 or not nb[-2].lstrip('-').isdigit():
        raise AssertionError(f'{label}: no numeric `$?` row before the '
                             f'prompt; screen tail: {nb[-6:]}')
    return int(nb[-2])


# --------------------------------------------------------------------
# RULINGS-1: the console shell is killable by KILL, ignores TERM when
# interactive (V7), and init brings it back. Each case boots its own
# machine, so none inherits an orphan.
# --------------------------------------------------------------------
STTY_COOKED = 'ICANON ECHO OPOST'
RESPAWN_STEPS = 40                # x 200k cycles; init needs ~3
MARKER_SET = 'JCM=old'
# shell_orphan's job must outlive the respawn and the harness's checks
# (~10M guest cycles, +3M under MAUX_GATE_RACE=late). 60 s is ~61M.
ORPHAN_LEN = 60
JOB_CMD = f'sleep {ORPHAN_LEN} &'
ST_LIVE = (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED)
_TAG = [0]


def two_prompts(rs):
    nb = [r.strip() for r in rs if r.strip()]
    return len(nb) >= 2 and nb[-1] == '$' and nb[-2] == '$'


def stty_report(c, label):
    """The console mode as a person reads it: type `stty` and parse
    its report. NOT VC_TMODE at the prompt: a shell whose line editor
    holds the console raw while it reads (TAB-A2) would make that cell
    read raw at every prompt, and these rows would go red for a reason
    that has nothing to do with a killed shell. A foreground command
    sees the mode the shell left for commands. The tag line lets the
    report be found with ECHO off, when the typed line is not on the
    glass."""
    _TAG[0] += 1
    tag = f'T{_TAG[0]}'
    V.t(c, f'echo {tag}; stty\r')
    rows = V.settle(c, at_prompt, f'{label}: `stty` report')
    rs = [r.strip() for r in rows]
    if tag not in rs or rs.index(tag) + 1 >= len(rs):
        raise AssertionError(f'{label}: no `stty` report after {tag}; '
                             f'tail {[r for r in rs if r][-4:]}')
    i = rs.index(tag)
    # only the prompt may follow the report: a `[n] Done ...` notice
    # here is the new shell reporting a job it never ran (a stale job
    # row, or an adopted child, that survived the respawn)
    extra = [r for r in rs[i + 2:] if r][:-1]      # the last is the prompt
    if extra:
        raise AssertionError(f'{label}: output after the `stty` report: '
                             f'{extra}')
    return rs[i + 1]


def ledger(c):
    """The bank ledger, read from the kernel's own cells, not
    inferred from `ps`: banks on the free list, banks held by a lazy-
    free tag, and banks a non-free PCB names. A bank in none of the
    three has leaked; one in two is double-booked. `total` is
    conserved by every spawn, exit and reap."""
    tbl = JB.pcbs(c)
    used = {b for (st, b, _p) in tbl.values() if st != ST_UNUSED}
    free = JB.peek_main(c, JB.sym_addr('PRC_FREE_CNT'))[0]
    states = JB.peek_main(c, JB.sym_addr('LZ_STATE'), JB.LZ_SLOT_CNT)
    held = sum(1 for x in states if x == JB.LZ_HELD)
    return {'free': free, 'held': held, 'used': len(used),
            'total': free + held + len(used)}


def marker(c, label, want):
    """Echo the marker variable. A shell that was killed and
    respawned has lost it; a shell that merely survived has not, and
    pid reuse (the respawn lands in the dead shell's slot) means the
    pid alone cannot tell the two apart."""
    cmd = 'echo M-$JCM-'
    V.t(c, cmd + '\r')
    rows = V.settle(c, at_prompt, f'{label}: marker echoed')
    out = [r.strip() for r in cmd_output(rows, cmd)]
    if out != [f'M-{want}-']:
        raise AssertionError(f'{label}: marker reads {out}, expected '
                             f'M-{want}- ({"a fresh shell" if not want else "the same shell"})')


def set_marker(c, label):
    V.t(c, MARKER_SET + '\r')
    V.settle(c, at_prompt, f'{label}: marker set')
    marker(c, label, 'old')


def runs_a_command(c, label):
    """A person types a command: it echoes (the echoed `$ echo`
    line) and runs (its output), on this console."""
    word = 'RESPAWNOK'
    cmd2 = f'echo {word}'
    V.t(c, cmd2 + '\r')
    rows = V.settle(c, at_prompt, f'{label}: `{cmd2}` ran')
    if [r.strip() for r in cmd_output(rows, cmd2)] != [word]:
        raise AssertionError(f'{label}: `{cmd2}` did not echo and run; '
                             f'tail {[r.rstrip() for r in rows if r.strip()][-4:]}')


def kill_and_respawn(c, label, cmd):
    """Type `cmd` (a force-kill of $$) and require a FRESH shell,
    cooked and echoing, that runs a command, within RESPAWN_STEPS."""
    V.t(c, cmd + '\r')
    rows = V.settle(c, at_prompt,
                    f'{label}: a prompt within the respawn window '
                    f'after `{cmd}`', max_steps=RESPAWN_STEPS)
    out = cmd_output(rows, cmd)
    if any('cannot kill' in r for r in out):
        raise AssertionError(f'{label}: `{cmd}` was REFUSED: '
                             f'{[r.rstrip() for r in out]}')
    marker(c, label, '')
    rep = stty_report(c, label)
    if rep != STTY_COOKED:
        raise AssertionError(f'{label}: the respawned shell\'s console '
                             f'reports `{rep}`, expected `{STTY_COOKED}`')
    runs_a_command(c, label)
    sh = shell_pid(c)
    print(f'[check-jobctl-a] {label}: `{cmd}` -> fresh shell (pid {sh}), '
          f'`{rep}`, a typed command ran', flush=True)
    return sh


# The killer's delay, seconds of emulated time. A case that wants the
# TERM to land ON a fixture (a foreground sleep, a `wait`, a half-read
# line) arms the killer first and the fixture second, so the delay must
# outlast everything the harness spends between the arming line and the
# moment the fixture is up: ~2.1M typing the 40-key arming line (50k per
# key), ~0.4M for its prompt, ~0.7M typing the fixture, ~0.4M for its
# prompt, and MAUX_GATE_RACE=late's 3M of lag after EACH line that arms
# something (the killer, and a `sleep N &` fixture is a second) -- ~10M
# before `wait` is even typed. The guest starts the killer's sleep ~1.4M
# after its line either way. 12 s is ~13.6M after the line: ~3.5M of
# margin on the late harness. The fixtures are lengthened to match
# (FG_LEN, JOB_LEN) so that a kill at ~13.6M still finds them running;
# await_killer asserts that it did.
KILLER_DELAY = 12
# shell_flap's orphan must be alive when the harness first sees init's
# back-off (late: +3M of lag first) and dead before the back-off ends
# (INIT_BACKH x 256 ticks = ~12.8 s): 8 s is ~8.2M, >4M inside both.
FLAP_JOB = 8
KILLJOB_LEN = 90                  # seconds: shell_kill b's `sleep` job
FG_LEN = 16                       # seconds: the foreground `sleep` the TERM must find running
JOB_LEN = 20                      # seconds: the background job a `wait` must still be waiting on
CYC_S = 1_020_500                 # guest cycles per emulated second
STEP_S = 200_000 / CYC_S          # one step() in emulated seconds


def drain_notices(c, label):
    """An empty line: the shell prints any finished-job notice before
    its next prompt, so the next row's output is not mixed with one."""
    V.t(c, '\r')
    V.settle(c, at_prompt1, f'{label}: job notices drained')


_KILLER = ['']


def start_killer(c, label, sig='', delay=KILLER_DELAY, target=None,
                 then=''):
    """A background `( sleep 2 ; kill [sig] <shell pid> )`: the TERM
    comes from ANOTHER process, at a moment the harness chooses by
    what it types next -- not from a `kill $$` the shell is waiting
    on (that raced: the signal landed inside FG_WAIT or after it).
    The harness knows the shell's pid; `$$` would name the subshell.
    `target` names another pid; `then` appends more of the subshell's
    list (the H3 row sends a second, different signal a second
    later)."""
    tgt = shell_pid(c) if target is None else target
    cmd = (f'( sleep {delay} ; kill {sig}{tgt}{then} ) > /dev/null '
           '2>&1 &')
    _KILLER[0] = cmd
    before = live_pids(c)
    V.t(c, cmd + '\r')
    V.settle(c, at_prompt1, f'{label}: killer started')
    # The subshell is a live PCB until its last `kill` has been
    # delivered, so "the killer has not fired yet" is a property the
    # harness can read (GATE-RACE-1), not a duration it must guess.
    _KPIDS[0] = frozenset(live_pids(c) - before)
    if not _KPIDS[0]:
        raise AssertionError(f'{label}: the overlap did not happen: the '
                             'killer already fired (it is not in the PCB '
                             'table) before its own prompt was back '
                             '(guest faster than the harness pace, or the '
                             'harness late; raise KILLER_DELAY)')
    return tgt


_KPIDS = [frozenset()]


def killer_pending(c, label, when):
    """The overlap's first half: the killer has NOT fired yet."""
    if not (_KPIDS[0] & live_pids(c)):
        raise AssertionError(
            f'{label}: the overlap did not happen: the killer already '
            f'fired {when} (guest faster than the harness pace, or the '
            'harness late; raise KILLER_DELAY)')


def await_killer(c, label, fixture, what, limit=1500):
    """The overlap's second half: poll until the killer has delivered
    its signal(s) -- its subshell has exited -- and require that at that
    poll every pid in `fixture` is still live, i.e. the signal landed ON
    the fixture and not after it."""
    for _ in GR.polls(c, limit):
        live = live_pids(c)
        if not (_KPIDS[0] & live):
            gone = set(fixture) - live
            if gone:
                raise AssertionError(
                    f'{label}: the overlap did not happen: {what} '
                    f'(pids {sorted(gone)} were already gone when the '
                    'killer fired)')
            _KPIDS[0] = frozenset()      # fired: its pids may be reused
            return
    raise AssertionError(f'{label}: the killer never finished '
                         f'({sorted(_KPIDS[0] & live_pids(c))} still live)'
                         ' ; screen:\n' + '\n'.join(V.rows(c)))


def await_new(c, base, label, what, n=1, limit=300):
    """The FIXTURE's own new pids (not the killer's): a property wait for
    the fixture to exist, never a duration."""
    for _ in GR.polls(c, limit):
        new = live_pids(c) - set(base) - _KPIDS[0]
        if len(new) >= n:
            return new
    raise AssertionError(f'{label}: {what}: {n} new process(es) never '
                         'appeared ; screen:\n' + '\n'.join(V.rows(c)))


def killer_done(c, label, base):
    settle_pids(c, lambda s: s == base, f'{label}: the killer finished',
                max_steps=600)


JOBLINE = re.compile(r'(\$|\[\d+\] \d+|\[\d+\][+-]?\s+Done\s.*)')


def stray_after(rows, cmd):
    """Rows after the echoed `$ cmd` line that are neither prompts
    nor job bookkeeping. None when `cmd` has scrolled off."""
    rows = [r.rstrip() for r in rows]
    idx = None
    for i, r in enumerate(rows):
        if r == '$ ' + cmd:
            idx = i
    if idx is None:
        return None
    return [r.strip() for r in rows[idx + 1:] if r.strip() and
            not JOBLINE.fullmatch(r.strip())]


def selftest():
    """Mutation self-test of the two H4 predicates: a stray line
    after the killer must be seen, a clean screen must not, and
    `$ $` on one row is a prompt for the ^C rows but not a single
    prompt."""
    clean = ['$ K &', '[1] 4', '$', '[1]+ Done   K', '$']
    assert stray_after(clean, 'K &') == [], 'clean screen flagged'
    dirty = clean[:3] + ['sh: oops'] + clean[3:]
    assert stray_after(dirty, 'K &') == ['sh: oops'], 'stray missed'
    assert stray_after(clean, 'other') is None
    assert at_prompt(['$ $']) and not at_prompt1(['$ $'])
    assert at_prompt1(['$']) and not at_prompt1(['$ x'])


def nothing_printed(c, label):
    """Since the killer's own echoed line, the glass holds only
    prompts and job bookkeeping (`[1] 4`, `[1]+ Done ...`): the TERM
    printed nothing (H4)."""
    stray = stray_after(V.rows(c), _KILLER[0])
    if stray:
        raise AssertionError(f'{label}: the TERM printed {stray}, '
                             'expected silence')


def term_ignored(c, label, sig=''):
    """An external TERM (`kill [sig] <pid>`) at the IDLE prompt: an
    interactive shell IGNORES it (V7 sh(1)). Same shell (marker
    kept), prompt live, nothing printed."""
    base = live_pids(c)
    start_killer(c, label, sig)
    killer_done(c, label, base)
    drain_notices(c, label)
    nothing_printed(c, label)
    marker(c, label, 'old')
    runs_a_command(c, label)
    print(f'[check-jobctl-a] {label}: external `kill {sig}`pid ignored '
          'at the idle prompt, same shell, prompt live', flush=True)


def case_shell_kill(c):
    """Row a: `kill -9 $$` kills and init respawns. Row b: TERM from
    ANOTHER process is IGNORED by an interactive shell at its idle
    prompt, `trap - 15` restores the ignore (not the kernel's
    terminate), and a CHILD of the shell still dies of TERM (the
    catch is not inherited). Plus the old case's `kill -0 $$` probe,
    unchanged. The wait/foreground/trap shapes are case_shell_term."""
    V.boot(c)
    label = 'shell_kill a'
    set_marker(c, label)
    kill_and_respawn(c, label, 'kill -9 $$')

    set_marker(c, 'shell_kill b')
    term_ignored(c, 'shell_kill b', '')
    term_ignored(c, 'shell_kill b', '-15 ')

    # `trap - 15` hands back the shell's own default, which for an
    # interactive shell is still to ignore; a user trap is case_shell_term
    V.t(c, "trap 'echo GOT' 15\r")
    V.settle(c, at_prompt, 'shell_kill b: trap set')
    V.t(c, 'trap - 15\r')
    V.settle(c, at_prompt, 'shell_kill b: trap reset')
    term_ignored(c, 'shell_kill b (after trap - 15)', '')
    print('[check-jobctl-a] shell_kill b: `trap - 15` restored the '
          'ignore', flush=True)

    # a child of the shell started from the prompt DIES of TERM:
    # spawn resets a catch to the default, so it is not inherited
    base = live_pids(c)
    # the job must still be running when `kill %1` lands, or "the job
    # died of TERM" is vacuous (the loop below breaks at once on a job
    # that already ran out): ~1M cycles of harness, +3M under late
    V.t(c, f'sleep {KILLJOB_LEN} &\r')
    pids = settle_pids(c, lambda s: len(s - base) == 1 and
                       at_prompt(V.rows(c)), 'shell_kill b: a job')
    job = (pids - base).pop()
    if job not in live_pids(c):
        raise AssertionError('shell_kill b: the overlap did not happen: '
                             f'the job ran out its `sleep {KILLJOB_LEN}` '
                             'before `kill %1` (raise KILLJOB_LEN)')
    V.t(c, 'kill %1\r')
    for _ in GR.polls(c, RESPAWN_STEPS):
        if pcb_states(c)[job][0] in (ST_ZOMBIE, ST_UNUSED):
            break
    else:
        raise AssertionError(f'shell_kill b: job {job} did not die of '
                             f'TERM: {pcb_states_str(c)} -- the shell\'s '
                             'catch leaked into its children')
    V.settle(c, at_prompt, 'shell_kill b: prompt after kill %1')
    print(f'[check-jobctl-a] shell_kill b: child {job} died of TERM '
          '(the catch is not inherited)', flush=True)

    set_marker(c, 'shell_kill probe')
    V.t(c, 'kill -0 $$\r')
    rows = V.settle(c, at_prompt, 'shell_kill: prompt after `kill -0 $$`')
    out = cmd_output(rows, 'kill -0 $$')
    if out:
        raise AssertionError('shell_kill: `kill -0 $$` printed '
                             f'something: {[r.rstrip() for r in out]}')
    status = last_status(c, 'shell_kill: `kill -0 $$`')
    if status != 0:
        raise AssertionError(f'shell_kill: `kill -0 $$` exited {status}, '
                             'expected 0 (a live-pid probe)')
    marker(c, 'shell_kill probe', 'old')
    print('[check-jobctl-a] shell_kill: `kill -0 $$` = 0, same shell '
          '(a probe kills nothing)', flush=True)


def run_until_prompt(c, label, limit=400):
    """Step until the prompt is back; returns the guest cycles stepped
    (the poll quantum is MAUX_GATE_RACE's to change, so callers must not
    count polls). The first 2 usual polls are skipped: a stale prompt."""
    t0 = c.gr_cycles
    for n, _ in enumerate(GR.polls(c, limit), 1):
        if n > GR.count(2) and at_prompt(V.rows(c)):
            return c.gr_cycles - t0
    raise AssertionError(f'{label}: no prompt in {limit} steps')


def case_shell_term(c):
    """RULINGS-1 round 2, G1 + G2: a TERM that is only the interactive
    shell's no-op catch is not an interruption. The kernel fails a
    blocking call out with ERR_INTR for it; the shell must drop it and
    retry (SIG_RETRY), not read it as EOF (the shell exited), abandon
    the foreground job (^C stopped reaching it) or mark every job
    Done early (`wait`). Only a USER trap interrupts."""
    label = 'shell_term'
    V.boot(c)
    # -- G1: the idle prompt ---------------------------------------
    set_marker(c, f'{label} idle')
    term_ignored(c, f'{label} idle', '')

    # -- G2: a foreground `sleep FG_LEN`, TERM mid-way -------------
    base = live_pids(c)
    start_killer(c, f'{label} fg')
    t0 = c.gr_cycles
    V.t(c, f'sleep {FG_LEN}\r')
    sleeper = await_new(c, base, f'{label} fg', 'the foreground sleep')
    killer_pending(c, f'{label} fg',
                   'before the foreground sleep started')
    await_killer(c, f'{label} fg', sleeper,
                 'the foreground sleep had already ended before the TERM')
    run_until_prompt(c, f'{label} fg')
    secs = (c.gr_cycles - t0) / CYC_S
    if secs < FG_LEN - 1.5:
        raise AssertionError(f'{label} fg: the prompt came back after '
                             f'{secs:.1f} s of a `sleep {FG_LEN}` (the '
                             'TERM abandoned the foreground job)')
    if live_pids(c) != base:
        raise AssertionError(f'{label} fg: a job outlived its prompt: '
                             f'{pcb_states_str(c)}')
    rows = V.rows(c)
    stray = [r.strip() for r in rows
             if ('Done' in r or 'Terminated' in r or 'Stopped' in r)
             and 'kill' not in r]
    if stray:
        raise AssertionError(f'{label} fg: stray job notice(s) {stray}')
    marker(c, f'{label} fg', 'old')
    print(f'[check-jobctl-a] {label}: TERM during a foreground '
          f'`sleep {FG_LEN}`: it ran {secs:.1f} s to completion, no '
          'stray notice', flush=True)

    # ... and ^C still reaches a foreground job after such a TERM
    base = live_pids(c)
    start_killer(c, f'{label} ^C')
    V.t(c, 'sleep 30\r')
    sleeper = await_new(c, base, f'{label} ^C', 'the foreground sleep')
    killer_pending(c, f'{label} ^C',
                   'before the foreground sleep started')
    # the TERM first (the property: the killer has fired), THEN the ^C
    await_killer(c, f'{label} ^C', sleeper,
                 'the foreground sleep had already ended before the TERM')
    step(c, 8)                       # let the TERM's retry settle
    ctrl_c(c)
    # ^C must reach the sleep NOW: allow a few seconds, not the 30
    # the sleep would take on its own (H5: with a long allowance this
    # row waited the job out and could not fail)
    n = run_until_prompt(c, f'{label} ^C', limit=GR.count(int(8 / STEP_S)))
    if n / CYC_S > 6:
        raise AssertionError(f'{label} ^C: the prompt took '
                             f'{n / CYC_S:.1f} s after ^C')
    if live_pids(c) != base:
        raise AssertionError(f'{label} ^C: ^C did not reach the '
                             f'foreground job after a TERM: '
                             f'{pcb_states_str(c)}')
    marker(c, f'{label} ^C', 'old')
    print(f'[check-jobctl-a] {label}: ^C still kills the foreground job '
          'after a TERM', flush=True)

    # -- G2: `wait` with a background job --------------------------
    drain_notices(c, f'{label} wait')
    base = live_pids(c)
    start_killer(c, f'{label} wait')
    V.t(c, f'sleep {JOB_LEN} &\r')
    V.settle(c, at_prompt, f'{label} wait: job started')
    job = await_new(c, base, f'{label} wait', 'the background job')
    V.t(c, 'wait\r')
    killer_pending(c, f'{label} wait', 'before `wait` was entered')
    await_killer(c, f'{label} wait', job,
                 'the background job had already finished before the TERM')
    step(c, 8)                       # `wait` must not have returned
    if at_prompt(V.rows(c)) or (job - live_pids(c)):
        raise AssertionError(f'{label} wait: `wait` returned with a '
                             f'`sleep {JOB_LEN}` running (the TERM '
                             'marked the job Done early)')
    t0 = c.gr_cycles
    run_until_prompt(c, f'{label} wait')
    secs = (c.gr_cycles - t0) / CYC_S
    if live_pids(c) != base:
        raise AssertionError(f'{label} wait: a job is still live after '
                             f'`wait`: {pcb_states_str(c)}')
    marker(c, f'{label} wait', 'old')
    print(f'[check-jobctl-a] {label}: TERM during `wait`: it waited a '
          f'further {secs:.1f} s for the job', flush=True)

    # -- a USER trap interrupts: it runs, and the shell lives ------
    drain_notices(c, f'{label} trap')
    base = live_pids(c)
    V.t(c, "trap 'echo T' 15\r")
    V.settle(c, at_prompt, f'{label} trap: set')
    start_killer(c, f'{label} trap')
    # the prompt is already printed when the TERM arrives, so the
    # trap's output follows it on the same row: `$ T`
    V.settle(c, lambda rs: any(re.fullmatch(r'(\$ )?T', r.strip())
                               for r in rs) and at_prompt(rs),
             f'{label} trap: the trap ran at the idle prompt',
             max_steps=400)
    killer_done(c, f'{label} trap', base)
    nT = sum(1 for r in V.rows(c) if re.fullmatch(r'(\$ )?T', r.strip()))
    if nT != 1:
        raise AssertionError(f'{label} trap: the trap ran {nT} times, '
                             'expected exactly once')
    drain_notices(c, f'{label} trap')
    marker(c, f'{label} trap', 'old')
    runs_a_command(c, f'{label} trap')
    print(f'[check-jobctl-a] {label}: with `trap echo T 15`, TERM at the '
          'idle prompt ran the trap and the shell lived', flush=True)

    # -- G3: a TRAPPED TERM interrupts `wait`; the job it leaves behind
    # must not come back as a ghost. wait's :stale marks the row Done
    # and the shell frees it with the job's pid still in it; when the
    # job really exits, JOB_FIND matched that pid in the FREE row and
    # the next prompt printed a second `Done` for it.
    base = live_pids(c)
    _KPIDS[0] = frozenset()              # an earlier killer's pids
    V.t(c, f'sleep {JOB_LEN} &\r')
    V.settle(c, at_prompt, f'{label} ghost: job started')
    job = await_new(c, base, f'{label} ghost', 'the background job')
    start_killer(c, f'{label} ghost')
    V.t(c, 'wait\r')
    killer_pending(c, f'{label} ghost', 'before `wait` was entered')
    await_killer(c, f'{label} ghost', job,
                 'the background job had already finished before the TERM')
    run_until_prompt(c, f'{label} ghost')
    killer_done(c, f'{label} ghost', base)       # the sleep has exited
    V.t(c, 'true\r')
    rows = V.settle(c, at_prompt, f'{label} ghost: `true` ran')
    ghost = cmd_output(rows, 'true')
    if ghost:
        raise AssertionError(f'{label} ghost: `true` printed '
                             f'{[r.rstrip() for r in ghost]} -- a freed '
                             'job row still matched a pid')
    print(f'[check-jobctl-a] {label}: a trapped TERM interrupted `wait`, '
          'and the abandoned job left no ghost notice', flush=True)


def case_shell_trapread(c):
    """RULINGS-1 round 3, H1-H3: what SIG_RETRY does with a TRAPPED
    signal at a blocking read."""
    label = 'shell_trapread'
    V.boot(c)
    set_marker(c, label)

    # -- H1: ^D is EOF even with a trap parked ----------------------
    V.t(c, "trap 'echo T' 15\r")
    V.settle(c, at_prompt1, f'{label} H1: trap set')
    start_killer(c, f'{label} H1')
    V.t(c, 'for i in 1 2; do\r')
    V.settle(c, lambda rs: [r.rstrip() for r in rs if r.strip()][-1:]
             == ['>'], f'{label} H1: the construct is open (`> `)')
    killer_pending(c, f'{label} H1', 'before the construct was open')
    await_killer(c, f'{label} H1', set(),
                 '')                          # the TERM lands at "> "
    step(c, 8)                                # and its trap runs
    c.call_tool('type', {'text': '\x04'})       # ^D, as ctrl_c types ^C
    V.settle(c, lambda rs: any('EOF with a construct still open' in r
                               for r in rs) and at_prompt1(rs),
             f'{label} H1: ^D ended the open loop as EOF', max_steps=400)
    rows = V.rows(c)
    nT = sum(1 for r in rows if re.fullmatch(r'(\$ |> )*T', r.strip()))
    if nT != 1:
        raise AssertionError(f'{label} H1: the trap ran {nT} times after '
                             'the EOF, expected once')
    drain_notices(c, f'{label} H1')
    marker(c, f'{label} H1', 'old')
    print(f'[check-jobctl-a] {label}: H1 a parked trap did not turn ^D '
          'into anything but EOF; the trap ran once, the shell lived',
          flush=True)

    # -- H3: two DIFFERENT trapped signals, both run once, in order -
    V.t(c, "trap 'echo A' 1\r")
    V.settle(c, at_prompt1, f'{label} H3: trap 1')
    V.t(c, "trap 'echo B' 15\r")
    V.settle(c, at_prompt1, f'{label} H3: trap 15')
    base = live_pids(c)
    sh = shell_pid(c)
    start_killer(c, f'{label} H3', sig='-1 ',
                 then=f' ; sleep 1 ; kill -15 {sh}')
    V.t(c, 'for i in 1 2; do\r')
    V.settle(c, lambda rs: [r.rstrip() for r in rs if r.strip()][-1:]
             == ['>'], f'{label} H3: the construct is open (`> `)')
    killer_pending(c, f'{label} H3', 'before the construct was open')
    await_killer(c, f'{label} H3', set(),
                 '')                          # HUP then TERM at "> "
    step(c, 8)                                # and both traps run
    V.t(c, 'echo L$i\r')
    V.t(c, 'done\r')
    V.settle(c, at_prompt1, f'{label} H3: the loop ran', max_steps=600)
    killer_done(c, f'{label} H3', base)
    rows = [r.strip() for r in V.rows(c)]
    na = sum(1 for r in rows if re.fullmatch(r'(\$ |> )*A', r))
    nb = sum(1 for r in rows if re.fullmatch(r'(\$ |> )*B', r))
    if (na, nb) != (1, 1):
        raise AssertionError(f'{label} H3: HUP trap ran {na}x, TERM trap '
                             f'ran {nb}x, expected once each; '
                             f'{[r for r in rows if r][-8:]}')
    ia = max(i for i, r in enumerate(rows)
             if re.fullmatch(r'(\$ |> )*A', r))
    ib = max(i for i, r in enumerate(rows)
             if re.fullmatch(r'(\$ |> )*B', r))
    if ia > ib:
        raise AssertionError(f'{label} H3: B ran before A (lowest '
                             'signal first)')
    print(f'[check-jobctl-a] {label}: H3 traps on 1 and 15, both parked '
          'inside a loop, ran once each, lowest first', flush=True)

    # -- H2: a half-read line is finished, not discarded -----------
    drain_notices(c, f'{label} H2')
    for cmd in ('echo "trap \'echo T\' 15" > /tmp/H2A',
                "echo -n 'echo AB' >> /tmp/H2A",
                'echo CD > /tmp/H2B',
                'echo cat /tmp/H2A > /tmp/PRODSH',
                'echo sleep 40 >> /tmp/PRODSH',
                'echo cat /tmp/H2B >> /tmp/PRODSH'):
        V.t(c, cmd + '\r')
        V.settle(c, at_prompt1, f'{label} H2: {cmd}')
    base = live_pids(c)
    # the producer writes `trap`, then HALF a line, sleeps, then the
    # rest; the consumer is a pipe-fed (non-interactive) sh. `$!` is
    # the pipeline's LAST stage: the consumer.
    V.t(c, 'sh /tmp/PRODSH | sh > /tmp/H2OUT &\r')
    V.settle(c, at_prompt1, f'{label} H2: pipeline started',
             max_steps=600)
    V.t(c, 'echo P$!P\r')
    rows = V.settle(c, at_prompt1, f'{label} H2: $! printed')
    pid = None
    for r in rows:
        m = re.fullmatch(r'P(\d+)P', r.strip())
        if m:
            pid = int(m.group(1))
    if pid is None:
        raise AssertionError(f'{label} H2: no pid from `echo $!`')
    # the TERM must land MID-LINE: the producer has written the trap and
    # half a line and is asleep, i.e. its `sleep` exists (the pipeline
    # is two shells and that sleep). Wait for that, then arm the killer.
    await_new(c, base, f'{label} H2', 'the producer asleep mid-line',
              n=3)
    start_killer(c, f'{label} H2', target=pid)
    fixture = live_pids(c) - set(base) - _KPIDS[0]
    killer_pending(c, f'{label} H2', 'before it was armed')
    await_killer(c, f'{label} H2', fixture,
                 'the pipeline had already finished before the TERM')
    settle_pids(c, lambda s: s == base, f'{label} H2: pipeline and '
                'killer finished', max_steps=1500)
    drain_notices(c, f'{label} H2')
    V.t(c, 'cat /tmp/H2OUT\r')
    rows = V.settle(c, at_prompt1, f'{label} H2: output read')
    got = [r.strip() for r in cmd_output(rows, 'cat /tmp/H2OUT')]
    if got != ['ABCD', 'T']:
        raise AssertionError(f'{label} H2: the pipe-fed shell wrote '
                             f'{got}, expected [\'ABCD\', \'T\'] (the '
                             'half-read line finished whole, then the '
                             'trap)')
    print(f'[check-jobctl-a] {label}: H2 a TERM landed mid-line; the '
          'line ran whole, then the trap', flush=True)


def case_shell_nested(c):
    """F7: only the LOGIN shell (the one init spawns) stamps the
    console cooked. `stty -echo` then a nested `sh` keeps echo off;
    `exit` returns to the parent, still off; `stty sane` puts it
    back."""
    label = 'shell_nested'
    V.boot(c)
    V.t(c, 'stty -echo\r')
    V.settle(c, at_prompt, f'{label}: `stty -echo` returned')
    base = live_pids(c)
    V.t(c, 'sh\r')                       # echo is off: nothing shown
    # the parent's prompt is already on the glass, so wait for the
    # nested shell itself: a new process AND a second prompt row
    settle_pids(c, lambda s: len(s - base) == 1, f'{label}: nested sh')
    V.settle(c, two_prompts, f'{label}: nested sh prompt')
    rep = stty_report(c, f'{label} (nested sh)')
    if rep != 'ICANON -ECHO OPOST':
        raise AssertionError(f'{label}: the nested sh left the console '
                             f'`{rep}`, expected `ICANON -ECHO OPOST` -- '
                             'it stamped a mode it was not asked to')
    V.t(c, 'exit\r')
    settle_pids(c, lambda s: s == base, f'{label}: the nested sh gone')
    V.settle(c, at_prompt, f'{label}: back in the parent')
    rep = stty_report(c, f'{label} (parent)')
    if rep != 'ICANON -ECHO OPOST':
        raise AssertionError(f'{label}: after `exit` the parent sees '
                             f'`{rep}`, expected `ICANON -ECHO OPOST`')
    V.t(c, 'stty sane\r')
    V.settle(c, at_prompt, f'{label}: `stty sane`')
    rep = stty_report(c, f'{label} (sane)')
    if rep != STTY_COOKED:
        raise AssertionError(f'{label}: `stty sane` left `{rep}`')
    print(f'[check-jobctl-a] {label}: a nested sh kept echo off, `exit` '
          'returned to the parent, `stty sane` restored', flush=True)


def case_shell_orphan(c):
    """Row c: a background job when the shell is killed. DECISION
    (docs/RULINGS-1-NOTES.md): the job survives, as a V7 `&` job
    survives its shell. RULINGS-1 had it adopted by SLOT IDENTITY (the
    respawn lands in the dead shell's slot, so the dangling parent
    pid named the new shell); ORPHAN-1 (2026-10-22) reparents it to
    init at the shell's death, so the new shell never owns it and its
    exit is reaped by INIT. It must not leak a PCB or a bank, and the
    new shell must not print a notice for a job it never ran (stale
    JOB_PID rows, zeroed at entry now)."""
    label = 'shell_orphan'
    V.boot(c)
    before = ledger(c)
    base = live_pids(c)
    set_marker(c, label)
    V.t(c, JOB_CMD + '\r')
    pids = settle_pids(c, lambda s: len(s - base) == 1 and
                       at_prompt(V.rows(c)),
                       f'{label}: background job and the prompt')
    job = (pids - base).pop()
    t_arm = c.gr_cycles
    sh = kill_and_respawn(c, label, 'kill -9 $$')
    tbl = pcb_states(c)
    if tbl[job][0] not in ST_LIVE and \
            c.gr_cycles - t_arm > (ORPHAN_LEN - 2) * CYC_S:
        raise AssertionError(f'{label}: the overlap did not happen: the '
                             f'job (pid {job}) ran out its `sleep '
                             f'{ORPHAN_LEN}` before the harness looked '
                             '(raise ORPHAN_LEN)')
    if tbl[job][0] not in ST_LIVE:
        raise AssertionError(f'{label}: the background job (pid {job}) '
                             f'is {ST_NAME.get(tbl[job][0], tbl[job][0])}'
                             ' after the shell died -- an `&` job '
                             'survives its shell')
    if tbl[job][1] != 1:
        raise AssertionError(f'{label}: the job (pid {job}) has parent '
                             f'{tbl[job][1]} after the respawn, wanted 1 '
                             f'(init): shell {sh} must not have adopted '
                             'it through the reused pid')
    print(f'[check-jobctl-a] {label}: job pid {job} survived, adopted by '
          f'init (parent 1, not the new shell {sh}); table '
          f'{pcb_states_str(c)}', flush=True)
    watch = WO.AdoptWatch(c, ROOT)
    try:
        for _ in range(GR.count(600)):         # ~20 emulated seconds
            watch.run(GR.quantum())
            if pcb_states(c)[job][0] == ST_UNUSED:
                break
        else:
            raise AssertionError(f'{label}: job {job} never finished and '
                                 f'was reaped by init: '
                                 f'{pcb_states_str(c)}')
        who = [r for p, r in watch.reaps if p == job]
    finally:
        watch.close()
    if who != [1]:
        raise AssertionError(f'{label}: job {job} was reaped by {who}, '
                             'wanted init (1) with no command typed')
    V.t(c, 'true\r')
    rows = V.settle(c, at_prompt, f'{label}: `true` ran')
    out = cmd_output(rows, 'true')
    if out:
        raise AssertionError(f'{label}: `true` printed {[r.rstrip() for r in out]}'
                             ' -- the new shell reported a job it never '
                             'ran (a stale job row survived the respawn)')
    tbl = {p: v for p, v in pcb_states(c).items() if v[0] != ST_UNUSED}
    if set(tbl) != {1, 2, sh}:
        raise AssertionError(f'{label}: after the job ended and a '
                             f'command ran, PCBs are '
                             f'{pcb_states_str(c)}; expected only '
                             f'1, 2 and the shell {sh}')
    after = ledger(c)
    if after['total'] != before['total']:
        raise AssertionError(f'{label}: bank ledger {before} before, '
                             f'{after} after -- a bank leaked or is '
                             'double-booked')
    print(f'[check-jobctl-a] {label}: init reaped the job, PCBs back to '
          f'1, 2, shell {sh}; ledger {before} -> {after}', flush=True)


def case_shell_stopped(c):
    """The orphan is already STOPPED (^Z) when the shell dies. A
    stopped job can never be continued by anyone but its parent, so
    it must not be left parked forever: ORPHAN-1 adopts it into init
    and sends it HUP then CONT (4.2BSD), the default HUP kills it ($81)
    and init reaps it."""
    label = 'shell_stopped'
    V.boot(c)
    before = ledger(c)
    base = live_pids(c)
    set_marker(c, label)
    V.t(c, 'sleep 100\r')
    pids = settle_pids(c, lambda s: len(s - base) == 1,
                       f'{label}: the foreground sleep')
    job = (pids - base).pop()
    # ^Z reaches only a job the shell has DECLARED foreground (the
    # spawn window, docs/CONSOLE.md sec 4): wait for that, not for a
    # number of steps
    wait_declared(c, {job}, f'{label}: the sleep declared foreground')
    JB.ctrl_z(c)
    V.settle(c, lambda rs: any('Stopped' in r for r in rs) and
             at_prompt(rs), f'{label}: ^Z stopped it')
    st = pcb_states(c)[job][0]
    if st != JB.ST_STOPPED:
        raise AssertionError(f'{label}: job {job} is '
                             f'{ST_NAME.get(st, st)}, expected STOPPED')
    sh = kill_and_respawn(c, label, 'kill -9 $$')
    V.t(c, 'true\r')
    rows = V.settle(c, at_prompt, f'{label}: `true` ran')
    if cmd_output(rows, 'true'):
        raise AssertionError(f'{label}: `true` printed '
                             f'{[r.rstrip() for r in cmd_output(rows, "true")]}')
    tbl = {p: v for p, v in pcb_states(c).items() if v[0] != ST_UNUSED}
    if set(tbl) != {1, 2, sh}:
        raise AssertionError(f'{label}: PCBs are {pcb_states_str(c)}; '
                             f'the stopped job {job} was not reaped')
    after = ledger(c)
    if after['total'] != before['total']:
        raise AssertionError(f'{label}: bank ledger {before} before, '
                             f'{after} after')
    print(f'[check-jobctl-a] {label}: stopped job {job} reaped; PCBs '
          f'1, 2, shell {sh}; ledger {before} -> {after}', flush=True)


def case_shell_raw(c):
    """Row d: the console comes back cooked after a kill of a shell
    that set raw mode."""
    label = 'shell_raw'
    V.boot(c)
    set_marker(c, label)
    V.t(c, 'stty raw\r')
    V.settle(c, at_prompt, f'{label}: `stty raw` returned')
    rep = stty_report(c, f'{label} (before)')
    if rep != '-ICANON ECHO OPOST':
        raise AssertionError(f'{label}: `stty` reports `{rep}` after '
                             '`stty raw` -- the row would be vacuous')
    print(f'[check-jobctl-a] {label}: console raw (`{rep}`); killing the '
          'shell', flush=True)
    kill_and_respawn(c, label, 'kill -9 $$')


def case_shell_flap(c):
    """Row e: six fast kills -> init backs off and still respawns.
    The sixth life also starts `sleep FLAP_JOB &` and is killed in the same
    breath, so the job outlives its shell INTO the back-off, when the
    shell's slot is empty: the slot-not-reused shape. ORPHAN-1: the
    job is init's child from the shell's death; init is polling the
    clock, not waiting, so the job sits as a ZOMBIE of init until the
    back-off ends and init's wait loop reaps it (before 2026-10-22
    PRC_REAP_ORPH reaped it from its own exit)."""
    label = 'shell_flap'
    V.boot(c)
    before = ledger(c)
    ck = CI.Clock(c)
    out = []
    calls = [0]

    def typed_kill():
        calls[0] += 1
        if calls[0] == CI.INIT_FLAPN + 1:
            ck.typ(f'sleep {FLAP_JOB} & kill -9 $$\r')
        else:
            ck.typ('kill -9 $$\r')
        return True

    n = CI.exit_until_backoff(ck, CI.INIT_FLAPN + 4, out, label,
                              before=typed_kill)
    if n is None:
        raise AssertionError('; '.join(out))
    if n != CI.INIT_FLAPN + 1:
        raise AssertionError(f'{label}: backed off after {n} kills; the '
                             f'limit is INIT_FLAPN={CI.INIT_FLAPN} fast '
                             f'deaths after the boot shell\'s own, so '
                             f'{CI.INIT_FLAPN + 1}')
    st = CI.init_state(c)
    print(f'[check-jobctl-a] {label}: {n} kills -> init backs off '
          f'(state {st})', flush=True)
    if st['done'] != 0xE5 or st['bo'] != 1:
        raise AssertionError(f'{label}: init state {st} during the '
                             'back-off, expected R_DONE=$E5 R_BACKOFF=1')
    tbl = pcb_states(c)
    # the killing `kill` died with its parent's exit status unread: it
    # is an adoptee too, a ZOMBIE of init until the back-off ends
    killers = [p for p, (s, par) in tbl.items()
               if s == ST_ZOMBIE and p not in (1, 2)]
    job = [p for p, (s, _par) in tbl.items()
           if s not in (ST_UNUSED, ST_ZOMBIE) and p not in (1, 2)]
    if not job:
        raise AssertionError(f'{label}: the overlap did not happen: the '
                             'orphaned sleep had already ended when the '
                             'harness saw the back-off (guest faster than '
                             'the harness pace, or the harness late; '
                             f'raise the sleep ({FLAP_JOB} s))')
    if len(job) != 1 or any(tbl[k][1] != 1 for k in killers):
        raise AssertionError(f'{label}: expected exactly the orphaned '
                             f'job (plus the killer\'s zombie, parent 1) '
                             f'in the back-off, table '
                             f'{pcb_states_str(c)}')
    job = job[0]
    if tbl[job][1] != 1:
        raise AssertionError(f'{label}: job {job} has parent {tbl[job][1]}'
                             ' in the back-off, wanted 1 (init)')
    print(f'[check-jobctl-a] {label}: job {job} outlived its shell into '
          f'the back-off, adopted by init (parent 1), no shell alive',
          flush=True)
    for _ in range(GR.count(400)):             # the sleep is FLAP_JOB s
        if pcb_states(c)[job][0] == ST_ZOMBIE:
            break
        if set(CI.shells(c)) - {job}:
            raise AssertionError(f'{label}: the shell came back before '
                                 f'the job ended: {pcb_states_str(c)} '
                                 '(lengthen the sleep or the window)')
        ck.step(GR.quantum(200_000))
    else:
        raise AssertionError(f'{label}: orphan {job} never exited into '
                             f'a zombie of init: {pcb_states_str(c)}')
    print(f'[check-jobctl-a] {label}: orphan {job} exited: a ZOMBIE of '
          'init, which is backing off (polling, not waiting)', flush=True)
    if CI.msg_count(c) != 1:
        raise AssertionError(f'{label}: {CI.msg_count(c)} copies of '
                             f'{CI.BACKOFF_MSG!r} on the console, '
                             'expected one')
    if not CI.wait_for_shell(ck, 150):
        raise AssertionError(f'{label}: init never brought a shell back '
                             'after the back-off -- it parked')
    if not CI.shell_works(ck, out, label):
        raise AssertionError('; '.join(out))
    for _ in range(GR.count(100)):             # init's wait loop
        if all(pcb_states(c)[p][0] == ST_UNUSED for p in [job] + killers):
            break
        ck.step(GR.quantum())
    else:
        raise AssertionError(f'{label}: init never reaped its zombie '
                             f'{job} after the back-off: '
                             f'{pcb_states_str(c)}')
    after = ledger(c)
    if after['total'] != before['total']:
        raise AssertionError(f'{label}: bank ledger {before} before, '
                             f'{after} after')
    print(f'[check-jobctl-a] {label}: shell back after the back-off and '
          f'it works; ledger {before} -> {after}', flush=True)


def main():
    if not os.path.exists(V.DISK):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    selftest()
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    fails = []
    try:
        c.initialize()
        V.boot(c)
        bg = None
        for name, fn in (('bg_survives', case_bg_survives),
                         ('script_whole', case_script_whole),
                         ('idle_prompt', case_idle_prompt),
                         ('orphan_zombie', case_orphan_zombie),
                         ('shell_kill', case_shell_kill),
                         ('shell_term', case_shell_term),
                         ('shell_trapread', case_shell_trapread),
                         ('shell_nested', case_shell_nested),
                         ('shell_orphan', case_shell_orphan),
                         ('shell_stopped', case_shell_stopped),
                         ('shell_raw', case_shell_raw),
                         ('shell_flap', case_shell_flap)):
            try:
                if name == 'bg_survives':
                    bg = fn(c)
                elif name in ('orphan_zombie', 'shell_kill',
                              'shell_term', 'shell_trapread',
                              'shell_nested', 'shell_orphan',
                              'shell_stopped', 'shell_raw',
                              'shell_flap'):
                    fn(c)
                else:
                    if bg is None:
                        # bg_survives failed before it had a job; the
                        # later cases still need one
                        bg = start_bg(c)
                    fn(c, bg)
                print(f'[check-jobctl-a] ok   {name}')
            except AssertionError as e:
                fails.append((name, str(e)))
                print(f'[check-jobctl-a] FAIL {name}: {e}', file=sys.stderr)
                V.boot(c)
                bg = None
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    if fails:
        print(f'[check-jobctl-a] FAIL: {len(fails)} of 12 cases',
              file=sys.stderr)
        return 1
    print('[check-jobctl-a] PASS: ^C kills the declared foreground job '
          '(and a script job whole) and nothing else -- a `&` job '
          'survives, an idle-prompt ^C kills nothing, an orphaned '
          "background subshell's exited grandchild is reaped, not "
          'left ZOMBIE forever, and the console shell is killable: '
          'init brings back a fresh cooked one, an `&` job survives '
          'without leaking a PCB or a bank, a raw console comes back '
          'cooked, and a kill flap backs off and still respawns')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
