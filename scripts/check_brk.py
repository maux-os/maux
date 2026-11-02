#!/usr/bin/env python3
"""check_brk.py -- a user BRK kills the process, not the machine
(`make check-brk`, docs/KBRK.md).

`$00` is BRK.  A jump into zeroed memory, a one-byte `$00` file, a
corrupted binary or a wild pointer all execute it, and the base kernel
answered EVERY one of them by parking the whole machine in
KRN_BRK_TRAP with interrupts masked: no tick, no ^C, no `kill` from
another console.  Now a user BRK is SIGTRAP (signal 5): the process dies
with wait status $85, its parent reaps it, and everything else runs on.

Boots the play image with fixtures a2til writes into /TMP, and types at
the shell (check_exec.py's rig).  Four boots:

  A. user rows (one boot)
     1. a one-byte `$00` BIN: sh names the death (`Trace/BPT trap`,
        KFIX3 item 3: sh names signals now, as docs/KBRK.md sec 33
        left open), `$?` is 133 ($85), and the
        console takes the next command.  The base kernel never prints
        the prompt again: the row waits a bounded time, then asserts
        the PARK signature (A=$42, I set, PC inside one instruction),
        so a dead machine is a named failure and not a hung harness.
     2. a second process alive at the time survives: a background
        `sleep 2` started BEFORE the BRK is reported `Done` (not
        `Terminated`) after it -- it kept being scheduled and the tick
        kept running -- and a CPU-BOUND background job (`jmp *`, always
        runnable, never blocked) is still alive and running after it.
     3. a wild jump into the zero slack of the $FFxx page
        (`jmp $FF60`) is the same death: the BRK is taken inside the
        language card.
     4. twenty BRKs in a row, then `ps`: every one reaped, no zombie,
        no slot or bank leaked (the free list holds 14 banks, so a
        leak ends the run at the fifteenth spawn).
     5. `brk | cat` finishes: the dead writer's pipe end is closed at
        the reap, so the reader sees EOF.
  B. a KERNEL BRK still halts (fresh boot): a BRK patched over
     KRN_EXIT's first byte, reached by every syscall, parks the
     machine in timer.s MAIN_IRQ_SHIM -- main's own language card has
     its own $FFFE, so a kernel BRK never reaches the per-bank door
     that kills.  No process is killed and K_BRK_MARKER stays clear.
  C. the idle process BRKing still halts (fresh boot, a root-tier
     process, parent 0): KRN_BRK_TRAP's marker and A=$42, nothing
     killed -- the scheduler cannot do without idle, and pid 1 (init)
     is the same tier.
  D. the console shell BRKing is killed and RESPAWNED by init (fresh
     boot): a BRK patched into the shell's resume point, undone the
     moment the shell is seen dead, and the console takes commands
     again.
  E. a BACKGROUND BRK leaves a foreground raw-mode program's console
     alone (fresh boot): `( sleep 2; brk ) > /dev/null &`, then vi (raw
     mode, VC_TMODE not cooked); when the BRK has happened VC_TMODE is
     what vi set.  PRC_DIE's tty backstop resets the console of a
     victim in that console's FOREGROUND job only (a ^C or a BRK of the
     job itself), not of a bystander.

Teeth: `--play base/play.po --listing base/MAUXPLAY.SYSTEM_Output.txt`
against the pre-KBRK kernel: A1 reads RED with the park named, and D
reads red the same way (B and C are green there: they pin what did
NOT change).

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_devfs as D  # noqa: E402
import check_exec as X  # noqa: E402
import check_mount as M  # noqa: E402
import gate_race as GR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A6: a program that patches its OWN TEXT, then BRKs.  Run 1 sees the
# flag at $0830 clear, sets it (a store into its own image, past the
# eight head bytes LZ_RETAIN re-reads) and BRKs.  A run that finds the
# flag SET exits 7 instead.  Loaded cold every time it is 133 every
# time; a bank retained warm from the dead run (its text is whatever
# the fault left) answers 7.
SELFP = bytearray(0x31)
SELFP[0:0x15] = bytes([
    0xAD, 0x30, 0x08,            # 0800 lda $0830
    0xD0, 0x07,                  # 0803 bne $080C
    0xEE, 0x30, 0x08,            # 0805 inc $0830   (patch own text)
    0x00,                        # 0808 brk
    0xEA, 0xEA, 0xEA,            # 0809 pad
    0xA9, 0x20, 0xA2, 0x08,      # 080C lda #$20 / ldx #$08 (parms $0820)
    0xA0, 0x02,                  # 0810 ldy #SYS_EXIT
    0x20, 0x00, 0xFF])           # 0812 jsr $FF00
SELFP[0x20] = 7                  # the exit status of the second path

FIXTURES = {
    '/TMP/BRK1': (b'\x00', 0x06),                   # BIN, aux $0800, BRK
    '/TMP/SELFP': (bytes(SELFP), 0x06),
    '/TMP/SPIN': (bytes([0x4C, 0x00, 0x08]), 0x06),   # jmp $0800: CPU-bound
    '/TMP/WILD': (bytes([0x4C, 0x60, 0xFF]), 0x06),  # jmp $FF60
}

PCB_BASE = 0x0800           # annex bank 0, 16 bytes a pid (mm.annex*.equ)
PCB_STATE, PCB_BANK, PCB_PARENT, PCB_SAVEDSP, PCB_EXIT = 1, 3, 4, 5, 6
STATUS_TRAP = 0x85
ST_BLOCKED = 3              # mm.annex2.equ PCB_BLOCKED
ST_LIVE = (1, 2, 3)         # RUNNABLE, RUNNING, BLOCKED
# A2's sleeper must outlive the harness: arming line + /tmp/brk1's spawn
# and death + its `echo $?` are ~2M guest cycles of harness, +3M under
# MAUX_GATE_RACE=late, against a sleep that starts ~1.4M after the line.
# 8 s is ~8.2M: >3M of margin, and A2 asserts the overlap held.
SLEEPER = 8
# E's script sleeps before the BRKer runs; vi must be raw (~3M after the
# harness types it, +3M late) when the BRK lands. 12 s: >8M of margin.
E_SLEEP = 12
WAIT_STEPS = 300            # x 200k cycles: bounded, the park is named
LISTING = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')


def sym(listing, name):
    """The address merlin32's own listing gives this label: listing
    addresses belong to ONE build, so they are read fresh."""
    pat = re.compile(r'\|\s*00/([0-9A-F]{4})[^|]*\|\s*' + name + r'\b')
    with open(listing, encoding='ascii', errors='replace') as fh:
        for line in fh:
            m = pat.search(line)
            if m:
                return int(m.group(1), 16)
    raise RuntimeError(f'{name} not found in {listing}')


def peek(client, addr, n=1, bank='main', aux_bank=0):
    a = {'addr': addr, 'count': n, 'bank': bank}
    if bank == 'aux':
        a['aux_bank'] = aux_bank
    r = client.call_tool('peek', a)
    return r.get('bytes') or r.get('data')


def poke(client, addr, byte, bank='main', aux_bank=0):
    a = {'addr': addr, 'bytes': [byte], 'bank': bank}
    if bank == 'aux':
        a['aux_bank'] = aux_bank
    client.call_tool('poke', a)


def pcbs(client, count=8):
    raw = peek(client, PCB_BASE, 16 * count, 'aux', 0)
    return [raw[p * 16:(p + 1) * 16] for p in range(count)]


def parked(client):
    """(is it halted, last regs).  Build-independent, the check_jobctl_a
    signature: PC inside one instruction while I is SET."""
    seen = []
    for _ in range(4):
        client.call_tool('step', {'cycles': 200_000})
        seen.append(client.call_tool('regs', {}))
    pcs = [r.get('pc', -1) for r in seen]
    masked = all(r.get('p', 0) & 0x04 for r in seen)
    return (max(pcs) - min(pcs) <= 3 and masked), seen[-1]


def sh_or_park(client, cmd, label, f):
    """sh(), but a console that never comes back is classified: parked
    (the defect) or merely slow.  Returns (rows, alive).  The wait is
    bounded (WAIT_STEPS) so a dead machine is a verdict, not a hang."""
    n0 = len(f)
    out = D.run_cmd(client, cmd + '\r', label, f, max_steps=WAIT_STEPS)
    if len(f) == n0:
        return out, True
    is_parked, r = parked(client)
    if is_parked:
        f.append(f'{label}: the whole MACHINE is parked (PC ${r["pc"]:04X}, '
                 f'A=${r["a"]:02X}, interrupts masked): a user BRK halted '
                 f'it -- no process-level death exists')
    return out, False


def boot(play, files):
    tmp = tempfile.mkdtemp(prefix='maux-brk-')
    img = os.path.join(tmp, 'play.po')
    shutil.copy(play, img)
    X.stage(img, files)
    return tmp, X.boot_client(img)


def part_a(client, f):
    sh, status, eq = M.sh, M.status, M.eq
    # -- 1: the one-byte BRK ----------------------------------------------
    out, alive = sh_or_park(client, '/tmp/brk1', 'A1', f)
    if not alive:
        f.append('A1: the remaining user rows are skipped (dead machine)')
        return
    eq('A1: /tmp/brk1: sh names the SIGTRAP death', out,
       ['Trace/BPT trap'], f)
    eq('A1: $? is 128+5 (SIGTRAP)', status(client, f, 'A1'), '133', f)
    eq('A1: the console takes the next command',
       sh(client, 'echo ok1', 'A1 echo', f), ['ok1'], f)
    # -- 2: a second process alive at the time survives -------------------
    out = sh(client, f'sleep {SLEEPER} > /dev/null &', 'A2 bg', f)
    eq('A2: the sleeper starts', [r.split(' ')[0] for r in out], ['[1]'], f)
    sleeper = int(out[0].split(' ')[1]) if out and ' ' in out[0] else 0
    out, alive = sh_or_park(client, '/tmp/brk1', 'A2', f)
    if not alive:
        return
    # THE OVERLAP, asserted (GATE-RACE-1): the BRK must have happened
    # while the sleeper was alive, or "a second process alive at the time
    # survives" is vacuous
    if pcbs(client, 16)[sleeper][PCB_STATE] not in ST_LIVE:
        f.append('A2: the overlap did not happen: the sleeper had already '
                 'ended when the BRK ran (guest faster than the harness '
                 'pace, or the harness late; raise SLEEPER)')
        return
    eq('A2: $? is 133 with a sleeper alive',
       status(client, f, 'A2'), '133', f)
    for _ in GR.polls(client, 400):           # the sleeper's own exit
        if pcbs(client, 16)[sleeper][PCB_STATE] not in ST_LIVE:
            break
    else:
        f.append(f'A2: the sleeper (pid {sleeper}) never finished')
        return
    eq('A2: the sleeper ran on and finished (Done, not Terminated)',
       sh(client, 'echo ok2', 'A2 echo', f),
       ['ok2', f'[1]+ Done   sleep {SLEEPER}'], f)
    out = sh(client, '/tmp/spin > /dev/null &', 'A2b bg', f)
    eq('A2b: the spinner starts', [r.split(' ')[0] for r in out], ['[1]'], f)
    spin = out[0].split(' ')[1] if out and ' ' in out[0] else '?'
    out, alive = sh_or_park(client, '/tmp/brk1', 'A2b', f)
    if not alive:
        return
    eq('A2b: $? is 133 with a CPU-bound job running',
       status(client, f, 'A2b'), '133', f)
    ps = sh(client, 'ps', 'A2b ps', f)
    row = [r.split() for r in ps[1:] if r.split()[:1] == [spin]]
    eq('A2b: the spinner is alive and RUNNABLE/RUNNING after the BRK',
       [r[1] for r in row], ['R'], f)
    sh(client, f'kill {spin}', 'A2b kill', f)
    # -- 3: a wild jump into the $FFxx page's zero slack --------------------
    out, alive = sh_or_park(client, '/tmp/wild', 'A3', f)
    if not alive:
        return
    eq('A3: $? is 133 for a BRK taken in the language card',
       status(client, f, 'A3'), '133', f)
    # -- 4: twenty in a row, nothing leaks -----------------------------------
    codes = []
    for i in range(20):
        out, alive = sh_or_park(client, '/tmp/brk1', f'A4 #{i}', f)
        if not alive:
            return
        codes.append(status(client, f, f'A4 #{i}'))
    eq('A4: twenty BRKs, every one 133', codes, ['133'] * 20, f)
    ps = sh(client, 'ps', 'A4 ps', f)
    try:
        pids = [int(r.split()[0]) for r in ps[1:]]
    except (ValueError, IndexError):
        f.append(f'A4: ps printed a row that is not `PID S BANK PPID`: '
                 f'{ps}')
    else:
        eq('A4: ps: init, idle, the shell and ps itself -- no leaked slot',
           (pids[:3], len(pids)), ([1, 2, 3], 4), f)
    # -- 6: a faulted process's bank is NOT retained warm --------------------
    got = []
    for i in range(3):
        out, alive = sh_or_park(client, '/tmp/selfp', f'A6 #{i}', f)
        if not alive:
            return
        got.append(status(client, f, f'A6 #{i}'))
    eq('A6: a self-patching BRKer loads cold every run (133, never 7)',
       got, ['133'] * 3, f)
    # -- 5: a pipeline with a dead writer ------------------------------------
    out, alive = sh_or_park(client, '/tmp/brk1 | cat; echo $?', 'A5', f)
    if alive:
        eq('A5: brk | cat finishes (the reader sees EOF)', out[-1:],
           ['0'], f)


def settle_then(client, steps=1500):
    for _ in range(steps):
        client.call_tool('step', {'cycles': 200_000})


def no_trap_death(client):
    return [p for p, r in enumerate(pcbs(client)) if r[PCB_EXIT] == STATUS_TRAP]


def part_b(play, listing, f):
    """A kernel BRK parks in MAIN_IRQ_SHIM and kills nobody."""
    exit_ = sym(listing, 'KRN_EXIT')
    shim = sym(listing, 'MAIN_IRQ_SHIM')
    marker = sym(listing, 'K_BRK_MARKER')
    tmp, client = boot(play, FIXTURES)
    try:
        poke(client, exit_, 0x00)
        client.call_tool('type', {'text': 'echo hi\r'})
        is_parked, r = parked(client)
        for _ in range(40):
            if is_parked:
                break
            is_parked, r = parked(client)
        if not is_parked:
            f.append('B: a BRK patched over KRN_EXIT did not halt the '
                     'machine')
            return
        pc = r['pc']
        if not (shim <= pc < shim + 0x80):
            f.append(f'B: parked at ${pc:04X}, outside MAIN_IRQ_SHIM '
                     f'(${shim:04X}): a kernel BRK must park in main\'s '
                     f'own handler')
        M.eq('B: K_BRK_MARKER stays clear (not the per-bank door)',
             peek(client, marker)[0], 0, f)
        M.eq('B: no process was killed by the BRK', no_trap_death(client),
             [], f)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


def idle_resume_pc(client, listing):
    idle = peek(client, sym(listing, 'K_IDLE_PID'))[0]
    row = pcbs(client)[idle]
    fr = peek(client, 0x100 + row[PCB_SAVEDSP] + 1, 6, 'aux', row[PCB_BANK])
    return idle, row[PCB_BANK], fr[4] | (fr[5] << 8)


def part_c(play, listing, f):
    """The idle process (root tier, parent 0) BRKing halts."""
    marker = sym(listing, 'K_BRK_MARKER')
    tmp, client = boot(play, FIXTURES)
    try:
        idle, bank, pc = idle_resume_pc(client, listing)
        poke(client, pc, 0x00, 'aux', bank)
        is_parked, r = parked(client)
        for _ in range(40):
            if is_parked:
                break
            is_parked, r = parked(client)
        if not is_parked:
            f.append(f'C: the idle process (pid {idle}) took a BRK and the '
                     f'machine did not halt')
            return
        M.eq('C: halted in KRN_BRK_TRAP: K_BRK_MARKER is $42',
             peek(client, marker)[0], 0x42, f)
        M.eq('C: idle was not killed', no_trap_death(client), [], f)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


def part_d(play, listing, f):
    """The console shell BRKing: killed, and init respawns it."""
    tmp, client = boot(play, FIXTURES)
    try:
        # The prompt is on the glass a few syscalls BEFORE the shell
        # blocks (the line editor brackets its read: mode, INT/TSTP,
        # foreground, geometry), and a frame read earlier than that is
        # the shell mid-setup, not the retry frame of its read. Wait
        # for the state the patch assumes: BLOCKED.
        for _ in range(GR.count(100, 20_000)):
            if pcbs(client)[3][PCB_STATE] == ST_BLOCKED:
                break
            GR.poll_step(client, 20_000)
        row = pcbs(client)[3]
        if row[PCB_STATE] != ST_BLOCKED:
            f.append('D: the console shell never blocked in its read')
            return
        if row[PCB_PARENT] != 1:
            f.append(f'D: pid 3 is not init\'s child (parent '
                     f'{row[PCB_PARENT]}): the console shell moved')
            return
        bank = row[PCB_BANK]
        fr = peek(client, 0x100 + row[PCB_SAVEDSP] + 1, 6, 'aux', bank)
        pc = fr[4] | (fr[5] << 8)
        orig = peek(client, pc, 1, 'aux', bank)[0]
        poke(client, pc, 0x00, 'aux', bank)
        client.call_tool('type', {'text': 'echo hi\r'})
        # -- stop on the very write that marks the shell dead, before
        # -- init can reap it: its PCB exit-status cell takes $85
        seen = False
        for _ in range(10):
            w = client.call_tool('until_write', {
                'addr': PCB_BASE + 3 * 16 + PCB_EXIT,
                'max_cycles': 30_000_000})
            if not w.get('hit'):
                break
            if w.get('value') == STATUS_TRAP:
                seen = True
                break
        poke(client, pc, orig, 'aux', bank)        # one shot
        if not seen:
            is_parked, r = parked(client)
            f.append('D: the console shell was never seen dead of SIGTRAP'
                     + (f' -- the machine is PARKED (PC ${r["pc"]:04X}, '
                        f'A=${r["a"]:02X})' if is_parked else ''))
            return
        out = None
        # `prompt_ready` alone is true the instant the dead shell's own
        # stale `$` is the last row -- the line editor does not echo
        # the keys it dies on, so no typed text hides it any more (the
        # learning is 01M3KY2AS0XJ22DY89S7R728GC's, a prompt check
        # satisfied by something that is not the new prompt). Wait for
        # the respawned shell itself: pid 3 blocked in its read with a
        # clean exit cell.
        for _ in range(GR.count(1500, 20_000)):
            row = pcbs(client)[3]
            if row[PCB_STATE] == ST_BLOCKED and row[PCB_EXIT] == 0:
                break
            GR.poll_step(client, 20_000)
        try:
            D.wait_for_screen(client, D.prompt_ready, 'D: respawned prompt',
                              max_steps=1500)
            out = M.sh(client, 'echo alive', 'D echo', f)
        except RuntimeError as e:
            f.append(str(e))
            return
        M.eq('D: init respawned the console shell', out[-1:], ['alive'], f)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


def part_e(play, listing, f):
    """A background BRK must not reset a foreground program's tty."""
    tmode = sym(listing, 'VC_TMODE')
    tmp, client = boot(play, FIXTURES)
    try:
        job = 0
        for cmd in (f"echo 'sleep {E_SLEEP}' > /tmp/dl",
                    'echo /tmp/brk1 >> /tmp/dl',
                    'sh /tmp/dl > /dev/null &'):
            out = M.sh(client, cmd, 'E setup', f)
        if out and out[0].startswith('[1] '):
            job = int(out[0].split()[1])
        client.call_tool('type', {'text': 'vi /tmp/ef\r'})
        before = 0x07
        for _ in GR.polls(client, 40, 250_000):   # until vi has gone raw
            before = peek(client, tmode)[0]
            if before != 0x07:
                break
        else:
            f.append('E: vi never put the console in raw mode: the '
                     'fixture is vacuous')
            return
        # THE OVERLAP, asserted (GATE-RACE-1): the script is still asleep
        # now, i.e. the BRKer has not run, so its BRK lands while vi owns
        # raw tty state -- not before vi started, not after it quit
        if not job or pcbs(client, 16)[job][PCB_STATE] not in ST_LIVE:
            f.append('E: the overlap did not happen: the background '
                     'script had already finished before vi went raw '
                     '(guest faster than the harness pace, or the '
                     'harness late; raise E_SLEEP)')
            return
        # the script sleeps, then the BRKer runs and dies; the script's
        # own exit is the property that says it is over
        for _ in GR.polls(client, 600, 250_000):
            if pcbs(client, 16)[job][PCB_STATE] not in ST_LIVE:
                break
        else:
            f.append('E: the background script never finished')
            return
        after = peek(client, tmode)[0]
        M.eq("E: a background BRK left vi's console mode alone",
             after, before, f)
        client.call_tool('type', {'text': '\x1b:q!\r'})
        try:
            D.wait_for_screen(client, D.prompt_ready, 'E: prompt after vi',
                              max_steps=600)
        except RuntimeError as e:
            f.append(str(e))
            return
        rows = D.screen_rows(client)
        M.eq('E: the background BRKer really ran (job reported finished)',
             any(r.startswith('[1]+') for r in rows), True, f)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build', 'play.po'))
    ap.add_argument('--listing', default=LISTING,
                    help='the listing of the kernel the play image carries '
                         '(rows B, C and D read symbol addresses from it)')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    listing = os.path.abspath(args.listing)
    for p in (play, listing):
        if not os.path.exists(p):
            print(f'check-brk: {p} missing -- make play-image')
            return 2
    f = []
    try:
        tmp, client = boot(play, FIXTURES)
        try:
            part_a(client, f)
        finally:
            client.close()
            shutil.rmtree(tmp, ignore_errors=True)
        part_b(play, listing, f)
        part_c(play, listing, f)
        part_d(play, listing, f)
        part_e(play, listing, f)
    except RuntimeError as exc:
        f.append(str(exc))
    if f:
        print(f'[check-brk] FAIL: {len(f)} row(s)')
        for x in f:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print('[check-brk] PASS: a user BRK is SIGTRAP; kernel BRK, idle and '
          'init still halt')
    return 0


if __name__ == '__main__':
    sys.exit(main())
