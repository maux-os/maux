#!/usr/bin/env python3
"""textaudit.py -- the RUNTIME writable-text audit (docs/STICKY.md sec 29).

WHAT THIS ANSWERS. Lazy free (docs/STICKY.md sec 27) hands a respawn the
bank a previous run of the same program left behind, WITHOUT recopying
the text. That is only correct if the text is still the program. `as`
is not -- it differs from its own `.bin` in ~8,685 of 15,968 bytes
after one run -- and `check_purity.PURE_PROGRAMS` (a source-level
audit) named exactly one clean program, `cat`. Nothing measured the
other thirty-two. This module measures them, and the answer is worse
than the question implied: 31 of 33 write their own text, and one of
those (`ld`) is BROKEN by its own warm respawn.

HOW, AND WHY NOT scripts/probe_astext.py's WAY. That probe polls the
tag table until a bank goes HELD and then diffs it. It found `as`
BEFORE sec 27's entry-head guard existed -- and the guard makes that
shape blind to exactly the case it was written for: a program whose
first 8 bytes move is REFUSED retention, so its bank never reaches
HELD and a HELD-watcher never sees it. Polling is also racy in the
other direction (a bank can be retained and re-taken between two
polls) and expensive (a peek pair per step).

So this stops on the KERNEL's own retire path instead:

  until_pc(LZ_RETAIN) -- PRC_FREE_BANK calls it for every dying
  process, with A = the bank being retired, BEFORE the kernel decides
  whether to keep the bank and before anything else can touch it.

At that instant the slot still carries the LIVE tag LZ_TAG wrote at
spawn: the bank, the image length GET_EOF found, and the absolute
pathname in the annex. That is a complete (program, bank, length)
triple with no guessing and no race -- one stop per process exit,
however long the process ran.

THE RANGE COMPARED, and why. LOAD_BASE .. LOAD_BASE+PRC_IMAGE_LEN,
i.e. exactly the bytes the cold loader reads off disk and exactly the
bytes lazy free declines to recopy. Nothing else is in scope: a
program's `dum` arena emits no bytes and therefore starts past the
image end (sec 21 anchors it at LIBA_BSSEND), the heap is above `brk`,
and the zeroed page is the kernel's. If a byte inside this range moved,
a warm respawn runs on the moved byte.

THREE OUTCOMES, not two -- the distinction is the whole point
(learning:01M0MEKF0H8AVAXJG4PZ7P5QXC):

  CLEAN       image byte-identical after real work. Warm respawn is
              provably safe for this program.
  DIRTY-HEAD  image moved AND the entry-head bytes moved. The kernel's
              own guard refuses the bank, the program cold-loads
              forever, and it is safe but never warm. `as` is this.
  DIRTY-TAIL  image moved, entry head INTACT. The bank IS retained and
              the next run of that program starts on mutated text.
              Safe only if every moved cell is written before it is
              read -- which is not statically decidable, and which
              only a poison-and-repeat gate (check-ls's shape) can
              test. This is the class the audit exists to enumerate.

WHAT A CLEAN RESULT DOES AND DOES NOT PROVE. It proves the program did
not write its text ON THE INPUTS IT WAS GIVEN. It is not a proof over
all inputs -- `as` was caught assembling a real file, and a run with
trivial arguments would have missed it. scripts/build_textaudit_image
.py's STEPS table is where each program's workload is chosen, and every
program's workload is stated there.

AND A CLEAN RESULT MEANS "the bytes did not CHANGE", not "nothing
wrote them". A program that stores over a cell the value it was
loaded with measures clean -- `date`'s clock buffer is exactly that on
the no-clock path (see check_purity.TEXT_IMMUTABLE's own caveat).
That is not a hole for lazy free's purposes, which only cares whether
the retained image still equals the file, but it is a hole for anyone
reading CLEAN as "has no writable text".
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

LOAD_BASE = 0x0800

# The symbols this audit reads out of merlin32's own -v1 symbol dump.
# NEVER hardcoded: every one of these is placed by a `ds` or by the
# assembler's PC, so all of them move whenever kernel source size
# changes (learning:01M0M9R7RT22JEPP2R0Y6J9MBX's own hygiene rule).
SYMS = ('LZ_RETAIN', 'LZ_BANKS', 'LZ_STATE', 'LZ_LENLO', 'LZ_LENHI',
        'LZ_PTH_ADDR', 'LZ_PTH_SIZE', 'LZ_SLOT_CNT', 'LZ_HEAD_LEN',
        'LZ_WARM')

# The harness's own progress cells (src/test/shtestb.s, aux bank 1),
# read only to tell "the run finished" from "the run wedged".
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292
R_SH_STATUS = 0x1203


def parse_num(tok):
    """One value from merlin32's symbol dump.

    Resolved symbols print as `$51AE` or as a plain decimal; UNRESOLVED
    equates print as the expression itself in braces --
    `LZ_PTH_ADDR = {$6000}+{{48}*{64}}` -- so the arithmetic has to be
    done here. Braces become parens, `$hex` becomes `0xhex`, and the
    result must contain nothing but digits and the four operators
    before it is evaluated.
    """
    tok = tok.strip().replace('{', '(').replace('}', ')')
    tok = re.sub(r'\$([0-9A-Fa-f]+)', lambda m: str(int(m.group(1), 16)), tok)
    if not re.fullmatch(r'[0-9+\-*/() ]+', tok):
        raise ValueError(f'cannot evaluate symbol value {tok!r}')
    return int(eval(tok))  # noqa: S307 -- guarded by the fullmatch above


def load_syms(symfile, names=SYMS, binary=None):
    """Read symbol values out of a merlin32 -v1 listing.

    STALENESS IS CHECKED FIRST, and it is not paranoia. This dump used
    to be a side effect of the .SYSTEM rule rather than a make target,
    so a dump older than the binary it describes was invisible: the
    first full sweep after this gate landed read one from three days
    earlier, predating lazy free entirely. That run failed loudly only
    by luck -- LZ_RETAIN did not exist yet, so the lookup below raised.
    A symbol that merely MOVED would have been read at its old address
    and the audit would have reported a confident verdict about the
    wrong memory. The Makefile fix (naming the dump as its own target)
    is the real one; this is the assertion that says so out loud if it
    ever regresses, because a gate reading stale symbols does not fail
    -- it lies.
    """
    if binary is not None and os.path.exists(binary):
        if os.path.getmtime(symfile) < os.path.getmtime(binary):
            raise RuntimeError(
                f'{symfile} is OLDER than {binary} -- the symbol dump '
                f'does not describe the binary this audit is about to '
                f'read. Rebuild with `merlin32 -v1`; do not trust a '
                f'verdict from it.')
    text = open(symfile, errors='replace').read()
    out = {}
    for name in names:
        m = re.search(r'^\s*' + re.escape(name) + r'\s*=\s*(\S+)\s*$',
                      text, re.MULTILINE)
        if not m:
            raise RuntimeError(f'{name} not in {symfile} -- is the harness '
                               f'assembled with merlin32 -v1?')
        out[name] = parse_num(m.group(1))
    return out


class Observation:
    """One process exit: what the kernel was about to retire."""

    __slots__ = ('path', 'bank', 'length', 'diffs', 'head_moved', 'warm')

    def __init__(self, path, bank, length, diffs, head_moved, warm=False):
        self.path = path
        self.bank = bank
        self.length = length
        self.diffs = diffs
        self.head_moved = head_moved
        # LZ_WARM is set by the LOADER when a spawn is served out of a
        # retained bank and stays set until the next spawn -- so at
        # THIS process's exit it still describes THIS process's spawn.
        # It is what turns "the text was mutated" into "and the next
        # run really did start on the mutated copy".
        self.warm = warm


def runs_of(offsets):
    """Contiguous runs, for a readable report."""
    out = []
    start = prev = None
    for off in offsets:
        if start is None:
            start = prev = off
            continue
        if off != prev + 1:
            out.append((start, prev))
            start = off
        prev = off
    if start is not None:
        out.append((start, prev))
    return out


class TextAuditor:
    """Stops on every process exit and diffs the dying bank's image."""

    def __init__(self, client, syms, images, label='textaudit'):
        self.client = client
        self.syms = syms
        # {DEVICE PATH: (program name, image bytes)}
        self.images = {k.upper(): v for k, v in images.items()}
        self.label = label
        self.observations = []
        self.unknown_paths = []
        self.untagged = 0
        # Stops at LZ_RETAIN's ADDRESS that were not the kernel --
        # see in_kernel() for what those are and why they matter.
        self.impostors = 0

    # -- emulator helpers ------------------------------------------
    def peek(self, addr, count, bank='main', aux_bank=None):
        args = {'addr': addr, 'count': count, 'bank': bank}
        if aux_bank is not None:
            args['aux_bank'] = aux_bank
        return bytes(self.client.call_tool('peek', args)['bytes'])

    def acc(self):
        r = self.client.call_tool('regs', {})
        for key in ('a', 'A', 'acc'):
            if key in r:
                return r[key] & 0xFF
        raise RuntimeError(f'regs gave no accumulator: {r}')

    def in_kernel(self):
        """Is the CPU executing the KERNEL's LZ_RETAIN, or an impostor?

        `until_pc` matches a 16-bit PC and nothing else. It cannot
        tell the kernel's LZ_RETAIN in main memory from an ordinary
        userland instruction that happens to sit at the same address
        inside a process bank -- and there is no reason one would not,
        because every process is linked at $0800 in its own 64K and
        the kernel lives in main at whatever address its source size
        puts it.

        That is not hypothetical. On 2026-08-23 LZ_RETAIN was $5456
        and `ld`'s MKPATH loop straddled it, so every character of
        every pathname `ld` canonicalised produced a "process exit"
        whose accumulator was that character: eighteen per run,
        spelling `LDNAMES` and `/mnt/MAUX/LDO1` down the log as bank
        numbers. They were harmless only by luck -- the accumulator
        held ASCII, and no live bank number is ASCII. Had a process
        been in bank 65 the audit would have diffed a LIVE bank at an
        arbitrary instant and reported a confident verdict about it.

        RAMRD is the discriminator: a maux process fetches its
        instructions from aux (RAMRD set, learning:
        01KW1GTYGVYAPQRGS5P7J66RWD), the kernel from main. One extra
        call per stop, and it REPLACES four peeks on every impostor.
        """
        sw = self.client.call_tool('softswitches', {})
        if 'RAMRD' not in sw:
            raise RuntimeError(
                f'softswitches reported no RAMRD: {sw} -- without it '
                f'this audit cannot tell a kernel stop from a userland '
                f'address collision')
        return not sw['RAMRD']

    def harness_cell(self, addr, count=1):
        return self.peek(addr, count, bank='aux', aux_bank=1)

    # -- the audit -------------------------------------------------
    def slot_tables(self):
        """LZ_BANKS/LZ_STATE/LZ_LENLO/LZ_LENHI for every slot.

        Read individually rather than as one span: the four arrays are
        adjacent today, and a future `ds` between them would silently
        turn this into a read of the wrong table.
        """
        n = self.syms['LZ_SLOT_CNT']
        return (self.peek(self.syms['LZ_BANKS'], n),
                self.peek(self.syms['LZ_STATE'], n),
                self.peek(self.syms['LZ_LENLO'], n),
                self.peek(self.syms['LZ_LENHI'], n))

    def slot_path(self, slot):
        """The slot's absolute pathname, straight out of the annex.

        The annex is aux BANK 0 (src/kernel/lazyfree.s's LZ_RD_PATH
        sets K_BC_SRCBANK to zero for it); the stored form is a length
        byte followed by the characters, which arrive with the high bit
        set or not depending on who staged them -- so mask it off.
        """
        size = self.syms['LZ_PTH_SIZE']
        raw = self.peek(self.syms['LZ_PTH_ADDR'] + size * slot, size,
                        bank='aux', aux_bank=0)
        n = raw[0]
        if n == 0 or n >= size:
            return None
        return ''.join(chr(b & 0x7F) for b in raw[1:1 + n]).upper()

    def observe_exit(self):
        """One stop at LZ_RETAIN: identify and diff the dying bank."""
        bank = self.acc()
        banks, states, lenlo, lenhi = self.slot_tables()
        slot = None
        for i in range(self.syms['LZ_SLOT_CNT']):
            # LZ_FIND_BNK's own rule: state 0 (LZ_FREE) means the slot
            # describes nothing, whatever LZ_BANKS holds.
            if states[i] != 0 and banks[i] == bank:
                slot = i
                break
        if slot is None:
            self.untagged += 1
            return
        path = self.slot_path(slot)
        length = lenlo[slot] | (lenhi[slot] << 8)
        if path is None or length == 0:
            self.untagged += 1
            return
        if path not in self.images:
            self.unknown_paths.append(path)
            return
        name, image = self.images[path]
        if length != len(image):
            # A tagged length that disagrees with the file on the host
            # means the audit is comparing against the wrong bytes --
            # louder than any diff it could report.
            self.observations.append(
                Observation(path, bank, length, None, None))
            return
        got = self.peek(LOAD_BASE, length, bank='aux', aux_bank=bank)
        diffs = [i for i in range(length) if got[i] != image[i]]
        head = self.syms['LZ_HEAD_LEN']
        head_moved = bool(diffs) and diffs[0] < head
        warm = self.peek(self.syms['LZ_WARM'], 1)[0] != 0
        print(f'[{self.label}] retire bank {bank:>2} {name:<8} '
              f'{length:>6} B  {len(diffs):>6} moved  '
              f'{"WARM" if warm else "cold"}'
              f'{"  ENTRY HEAD MOVED" if head_moved else ""}')
        self.observations.append(
            Observation(path, bank, length, diffs, head_moved, warm))

    def run(self, budget_cycles=2_000_000_000, slice_cycles=40_000_000):
        """Drive to completion, stopping at every process exit.

        `until_pc` returns when the PC reaches LZ_RETAIN or when its own
        max_cycles runs out. A miss is not necessarily the end of the
        run -- `as` assembling a 14KB module goes a long time between
        exits -- so a miss only ends the loop once the harness says it
        is done.

        THE STEP AFTER EVERY HIT IS LOAD-BEARING. `until_pc` tests its
        condition BEFORE advancing, so calling it again while the PC is
        still on the target returns instantly with elapsed=0, forever:
        the first version of this loop reported fifty identical
        observations of one `as` exit in half a second and would have
        passed a run in which nothing else ever executed. Stepping off
        the address first is what makes the next call mean "the NEXT
        process exit". Sixteen cycles is more than the longest 65C02
        instruction and less than LZ_RETAIN's first branch, so the
        tag the observation just read is untouched either way.
        """
        total = 0
        stops = 0
        while total < budget_cycles:
            r = self.client.call_tool('until_pc', {
                'pc': self.syms['LZ_RETAIN'], 'max_cycles': slice_cycles})
            total += r.get('elapsed', slice_cycles)
            if r.get('hit'):
                if self.in_kernel():
                    self.observe_exit()
                    stops += 1
                else:
                    self.impostors += 1
                self.client.call_tool('step', {'cycles': 16})
                total += 16
                continue
            if self.harness_cell(R_DONE)[0] in (0xAA, 0xEE):
                break
        done = self.harness_cell(R_DONE)[0]
        err = self.harness_cell(R_ERR)[0]
        step = self.harness_cell(R_STEP)[0]
        status = self.harness_cell(R_SH_STATUS)[0]
        print(f'[{self.label}] {stops} process exits observed '
              f'({self.impostors} userland stop(s) at the same address '
              f'rejected), ~{total} cycles; done=${done:02X} '
              f'err=${err:02X} step={step} sh_status=${status:02X}')
        return {'done': done, 'err': err, 'step': step, 'sh_status': status,
                'stops': stops, 'impostors': self.impostors}


def boot(disk):
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.require_tools('until_pc', 'regs', 'peek')
    client.call_tool('reset', {'backend': 'fast'})
    r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
    if r.get('ok') is False:
        client.close()
        raise RuntimeError(f'mount_disk failed: {r}')
    return client
