#!/usr/bin/env python3
"""profile_f2.py -- a PLASMA-aware SAMPLING profiler for nas (the native
maux assembler, written in PLASMA bytecode). Answers the question
scripts/profile_nas_vs_as.py's throughput numbers can't: WHERE the
execution cost actually goes, attributed to individual PLASMA
functions inside nas.mod, not just a slope between two source sizes.

METHOD (docs/AS-PROFILE.md is the throughput companion; this is a sibling
MEASUREMENT script, not a gate -- no pass/fail, not in CHECK_ALL_TARGETS).

2026-09-18: sample at deterministic jittered 3,500-8,499-cycle intervals;
check RAMRD/ALTZP as well as the physical bank; classify native helpers by
actual PC from the ACME report. Only VM execution is attributed through IP.
The older all-IP method attributed native helpers' temporary Y to bytecode.
Function attribution remains approximate during the VM's IP transitions.

THE IP MECHANICS (verified against src/bin/plasmavm.s, not re-derived):
PLASMA's bytecode instruction pointer is NOT a plvmzp.inc symbol -- it is
the self-modifying operand of FETCHOP ($F1 LDA $FFFF,Y) in the page-0
inner loop. The operand bytes live at ZERO PAGE $F2 (IPL) / $F3 (IPH),
patched to the current bytecode base; the running offset is the live 6502
Y register. So the exact current bytecode address is:

    IP = (peek($F3) << 8 | peek($F2)) + regs().y

These are cells in the RUNNING PROCESS's own zero page -- maux is a
bank-per-process kernel (pid == aux bank, HACKING.md), so while nas is
mid-assembly its ZP lives in ITS OWN RamWorks bank, not main's. The
peek() MCP tool can read any bank directly (bank='aux', aux_bank=N)
regardless of which bank is *currently selected* -- but the running
process's own Y register is a SINGLE shared 6502 register, so regs().y is
only meaningful for process N at the instant N is actually the CPU's live
context. softswitches()['ramworks_bank'] reports that live context on
every call, so EVERY sample checks it: if it doesn't match nas's own bank
(established empirically after the command starts -- see find_nas_bank()),
nas is switched out (kernel trap, e.g. mid-syscall file I/O) and the
sample is bucketed 'off-cpu' rather than turned into a bogus IP by
pairing bank-N's frozen IPL/IPH with some OTHER context's live Y.

SYMBOLIZATION: nas.mod's own def table, recovered from acme's own
listing (-r report) of build/nas.a (NOT the module's runtime def
directory -- that's for cross-module EXTERNAL call resolution, not
needed here). Every `def NAME(...)` in src/asm/nas.pla compiles to a
label `_C0nn` immediately followed by a comment `; NAME()` in the
report; the address of the first emitted byte after that label is the
def's entry point. Offsets are computed relative to _SEGBEGIN (the
report's own $2000 baseline for this build), so at RUNTIME the def's
address is just `load_base + offset`.

LOAD BASE: nas.mod is loaded onto the process's heap above rt.mod's own
fixed $2000 -- NOT at a fixed address (rt is flat; nas/args/fileio stack
above it). Found empirically but PRECISELY, not guessed, via a 1 KB-
chunked memory scan of the process's own aux bank for a known BYTECODE
signature -- not a guess from heap-layout arithmetic, no ambiguity from
sample clustering.

FIRST ATTEMPT (recorded so the next person doesn't repeat it): the
module's on-DISK header (file offset 12) holds 16 bytes of pure DATA --
three back-to-back DCI import-name strings (CMDSYS/FILEIO/ARGS, from
nas.pla's own `include` order) that are never touched by relocation
fixups. Searching memory for those bytes NEVER matched, even after
80M+ cycles of settling. Reading raw memory at $2000 in the process's
own bank showed why: $2000 holds *rt.mod*, not nas.mod (rt is the flat
runtime loaded first, at the fixed address), and rt.mod's own PUT-name
table happens to contain a plain-ASCII (not DCI) "CMDSYS" substring --
a coincidental near-miss that cost real debugging time before the actual
cause (the header/import dictionary is NOT copied into the resident
module image at all -- the loader consumes it for import resolution at
load time and only the header words used at runtime (DEFCNT/INIT) plus
the bytecode segment itself, from _SUBSEG onward, end up resident) was
found by testing directly against known memory contents.

WORKING SIGNATURE: the first def's own compiled BYTECODE BODY (e.g.
`toup()`, nas.pla's first `def`) -- pulled straight from build/nas.mod
at its file offset (def.off + 2, skipping the 2-byte length word) -- IS
guaranteed resident (it's the actual code that executes) and, for a
small leaf function using only locals/immediates/relative branches (no
CALL/LA to another def), is position-independent: identical bytes on
disk and in memory regardless of load address. Verified directly:
found on the first re-scan after ~5M settle cycles, at an address that
decodes to a sane load base above rt/fileio/args. To stay correct if
nas.pla's function bodies ever change shape, find_load_base() tries
several of the EARLY small defs as candidate signatures in the same
scan pass, not just the first -- see find_load_base()/build_signatures().

Run: `python3 scripts/profile_f2.py` (needs `make profile-image` first,
i.e. build/profile.po + build/nas.a + build/nas.mod present).
"""
import os
import re
import subprocess
import sys
import bisect
import collections
import random

from textaudit import load_syms

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'profile.po')
NAS_A = os.path.join(ROOT, 'build', 'nas.a')
NAS_MOD = os.path.join(ROOT, 'build', 'nas.mod')
NAS_REPORT = os.path.join(ROOT, 'build', 'nas_report_f2.txt')
NAS_REPORT_MOD_SCRATCH = os.path.join(ROOT, 'build', 'nas_f2_scratch.mod')

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_nas.py precedent)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

IPL_ADDR = 0xF2              # plasma.s: IP = IPL = FETCHOP+1
IPH_ADDR = 0xF3              # plasma.s: IPH = IPL+1

# How many of the EARLY (small) defs to try as load-base signatures --
# see module docstring "WORKING SIGNATURE". Each candidate's bytes are
# pulled live from build/nas.mod (def.off + 2, skipping the length word).
SIGNATURE_CANDIDATE_DEFS = 6

SAMPLE_CHUNK = 100_000        # bank-identification probes; main samples jitter
SETTLE_CHUNK = 200_000        # cycles per boot/settle poll (untimed)
BOOT_MAX_STEPS = 1200
SETTLE_MAX_STEPS = 200        # generous: module load + first several lines
MAIN_LOOP_MAX_SAMPLES = 100000  # bounded even for older/slower nas builds
DONE_CHECK_PERIOD = 25        # screen_text() polled every 25 samples to detect
                               # the shell prompt returning (keeps the tight
                               # per-sample loop to 3 MCP calls: step/softswitches/
                               # peek+regs)

FIXTURES = [
    ('prof.large', 'PROFLG.S', 'F2OUT1'),
    ('profleanlarge', 'PROFLNLG.S', 'F2OUT2'),
]


# ---------------------------------------------------------------------
# def table (symbolization) -- acme's own -r report on build/nas.a
# ---------------------------------------------------------------------
def build_def_table():
    if not os.path.exists(NAS_A):
        print(f'error: {NAS_A} missing -- run `make profile-image` first',
              file=sys.stderr)
        sys.exit(2)
    subprocess.run(
        ['acme', '--setpc', '8190', '-r', NAS_REPORT,
         '-o', NAS_REPORT_MOD_SCRATCH, os.path.basename(NAS_A)],
        cwd=os.path.dirname(NAS_A), check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(NAS_REPORT) as f:
        lines = f.readlines()

    segbegin = None
    for i, l in enumerate(lines):
        if re.match(r'^\s*\d+\s+_SEGBEGIN', l):
            for j in range(i + 1, i + 3):
                m = re.match(r'\s*\d+\s+([0-9a-f]{4})\s', lines[j])
                if m:
                    segbegin = int(m.group(1), 16)
                    break
            break
    if segbegin is None:
        raise RuntimeError('could not find _SEGBEGIN address in acme report')

    segend = None
    for i, l in enumerate(lines):
        if re.match(r'^\s*\d+\s+_SEGEND', l):
            for j in range(i - 1, max(i - 30, 0), -1):
                am = re.match(r'\s*\d+\s+([0-9a-f]{4})\s+([0-9a-f]+)\s', lines[j])
                if am:
                    segend = int(am.group(1), 16) + len(am.group(2)) // 2
                    break
            break
    if segend is None:
        raise RuntimeError('could not find _SEGEND address in acme report')

    defs = []
    pat = re.compile(r'_C(\d{3}) \s*;\s*(\w+)\(\)')
    for i, l in enumerate(lines):
        m = pat.search(l)
        if not m:
            continue
        name = m.group(2)
        addr = None
        for j in range(i + 1, min(i + 300, len(lines))):
            am = re.match(r'\s*\d+\s+([0-9a-f]{4})\s', lines[j])
            if am:
                addr = int(am.group(1), 16)
                break
        if addr is None:
            raise RuntimeError(f'no address found after def {name}()')
        defs.append((addr, name))

    defs.sort()
    table = []  # list of (off, off_end, name), sorted by off
    for i, (addr, name) in enumerate(defs):
        off = addr - segbegin
        off_end = (defs[i + 1][0] - segbegin) if i + 1 < len(defs) else (segend - segbegin)
        table.append((off, off_end, name))

    seglen = segend - segbegin
    print(f'[profile-f2] def table: {len(table)} defs, nas.mod bytecode '
          f'segment length ${seglen:04X} ({seglen} bytes)')
    return table, seglen


def classify_offset(def_table, seglen, off):
    """off is IP - load_base. Returns a bucket name."""
    if off < 0 or off >= seglen:
        return None  # outside nas.mod entirely -- caller buckets as rt/lib
    # def_table sorted by off; binary search
    starts = [d[0] for d in def_table]
    i = bisect.bisect_right(starts, off) - 1
    if i < 0:
        return 'nas-prologue'  # before the first def (module header/imports)
    off0, off1, name = def_table[i]
    if off0 <= off < off1:
        return name
    return 'nas-gap'  # between two defs (padding/alignment, rare)


def native_table(def_table):
    """Native asm precedes bytecode; use actual PC there, never stale IP/Y."""
    with open(NAS_REPORT) as stream:
        lines = stream.readlines()
    starts = []
    for i, line in enumerate(lines):
        match = re.search(r'_A\d{3}\s*;\s*(\w+)\(\)', line)
        if match:
            for following in lines[i + 1:]:
                addr = re.match(r'\s*\d+\s+([0-9a-f]{4})\s+[0-9a-f]+\s',
                                following)
                if addr:
                    starts.append((int(addr[1], 16) - 0x2000, match[1]))
                    break
    starts.sort()
    return [(off, starts[i + 1][0] if i + 1 < len(starts)
             else def_table[0][0], name)
            for i, (off, name) in enumerate(starts)]


# ---------------------------------------------------------------------
# emulator plumbing (mirrors profile_nas_vs_as.py's boot_client/wait_for)
# ---------------------------------------------------------------------
def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def live_rows(rows):
    return [r for r in rows if r.strip()]


def bare_prompt(rows):
    live = live_rows(rows)
    return bool(live) and live[-1].strip() == '$'


def wait_for(client, predicate, label, max_steps, chunk_cycles=SETTLE_CHUNK):
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': chunk_cycles})
        rows = screen_rows(client)
        if predicate(rows):
            return
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                        + '\n'.join(rows))


def boot_client():
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.call_tool('reset', {'backend': 'fast'})
    for addr, val in ((PT_F40_ADDR, PT_F40_MAG1), (PT_F40B_ADDR, PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val], 'bank': 'main'})
    client.call_tool('mount_disk', {'path': DISK})
    wait_for(client, bare_prompt, 'boot shell prompt', BOOT_MAX_STEPS)
    return client


# ---------------------------------------------------------------------
# process-bank + load-base discovery
# ---------------------------------------------------------------------
def current_bank(client):
    return client.call_tool('softswitches', {}).get('ramworks_bank')


def find_nas_bank(client, shell_bank, tries=40):
    """After the command has been typed, step forward until a RamWorks
    bank OTHER than the shell's own bank is live (the shell forked a
    child for the foreground command; pid == bank, HACKING.md) -- take a
    majority vote over a few probes to ride out any transient kernel
    (bank 0) blips during the fork/exec/module-load sequence."""
    votes = collections.Counter()
    for _ in range(tries):
        client.call_tool('step', {'cycles': SAMPLE_CHUNK})
        b = current_bank(client)
        if b is not None and b != shell_bank:
            votes[b] += 1
        if sum(votes.values()) >= 8:
            break
    if not votes:
        raise RuntimeError('never observed a RamWorks bank other than the '
                            f'shell bank ({shell_bank}) after typing the command')
    return votes.most_common(1)[0][0]


def build_signatures(def_table):
    """Candidate (off, bytes) signatures: the first several small defs'
    own compiled bytecode bodies, read straight from build/nas.mod. Each
    is resident-and-position-independent AS LONG AS that def contains no
    CALL/LA to another def/global (an absolute address the loader would
    fix up per load address) -- true for a leaf function on locals only.
    Trying several candidates in the same scan pass makes this self-
    healing if a future nas.pla edit changes what the first def looks
    like. See module docstring "WORKING SIGNATURE"."""
    with open(NAS_MOD, 'rb') as f:
        modbytes = f.read()
    sigs = []
    for off, off_end, name in def_table[:SIGNATURE_CANDIDATE_DEFS]:
        file_off = off + 2  # skip the 2-byte length word before _SEGBEGIN
        length = off_end - off
        sig = modbytes[file_off:file_off + length]
        if len(sig) >= 8:  # skip degenerate/empty defs
            sigs.append((name, off, sig))
    return sigs


def _scan_once(client, nas_bank, sigs, ceiling, chunk):
    """One linear pass over [0x2000, ceiling) in this bank, checking
    every candidate signature against the same fetched bytes. Returns
    (found_addr, def_off, name) or None."""
    max_siglen = max(len(s) for _, _, s in sigs)
    addr = 0x2000
    prev_tail = b''
    while addr < ceiling:
        n = min(chunk, ceiling - addr)
        r = client.call_tool('peek', {'addr': addr, 'count': n,
                                       'bank': 'aux', 'aux_bank': nas_bank})
        data = bytes(r['bytes'])
        hay = prev_tail + data
        for name, off, sig in sigs:
            idx = hay.find(sig)
            if idx >= 0:
                found_at = addr - len(prev_tail) + idx
                return found_at, off, name
        prev_tail = data[-(max_siglen - 1):]
        addr += n
    return None


def find_load_base(client, def_table, nas_bank, ceiling=0xC000, chunk=1024,
                    settle_chunk=5_000_000, max_rounds=12):
    """Locate nas.mod's runtime load base: repeatedly scan the process's
    own aux bank for any of build_signatures()'s candidate bytecode
    bodies, stepping forward between rounds to let module loading (disk
    I/O -- not instant) finish if the first pass is too early. Returns
    the load base, or None if never found within the round budget."""
    sigs = build_signatures(def_table)
    for round_i in range(max_rounds):
        hit = _scan_once(client, nas_bank, sigs, ceiling, chunk)
        if hit is not None:
            found_at, def_off, name = hit
            load_base = found_at - def_off
            print(f'[profile-f2] load-base signature match: {name}() found '
                  f'at ${found_at:04X} (round {round_i}) -> load_base='
                  f'${load_base:04X}')
            return load_base
        client.call_tool('step', {'cycles': settle_chunk})
    return None


# ---------------------------------------------------------------------
# the sampling loop
# ---------------------------------------------------------------------
def run_fixture(tag, srcname, objname, def_table, seglen):
    native = native_table(def_table)
    vm = load_syms(os.path.join(ROOT, 'build', 'plasma.bin_Output.txt'),
                   names=('DINTRP', 'START'),
                   binary=os.path.join(ROOT, 'build', 'plasma.bin'))
    rng = random.Random(618)
    client = boot_client()
    try:
        client.call_tool('type', {'text': 'cd /mnt/MAUX/pllib\r'})
        wait_for(client, bare_prompt, f'{tag} cd prompt', 400, chunk_cycles=50_000)
        shell_bank = current_bank(client)
        print(f'[profile-f2] [{tag}] shell bank = {shell_bank}')

        cmd = f'plasma NAS -o {objname} {srcname}\r'
        client.call_tool('type', {'text': cmd})

        # Phase 1: wait for the bare prompt to visibly go away (matches
        # profile_nas_vs_as.py's own false-prompt-trap guard).
        rows = screen_rows(client)
        n = 0
        while bare_prompt(rows):
            client.call_tool('step', {'cycles': 50_000})
            rows = screen_rows(client)
            n += 1
            if n > 400:
                raise RuntimeError(f'[{tag}] command never started echoing')

        nas_bank = find_nas_bank(client, shell_bank)
        print(f'[profile-f2] [{tag}] nas process bank = {nas_bank}')

        load_base = find_load_base(client, def_table, nas_bank)
        if load_base is None:
            print(f'[profile-f2] [{tag}] WARNING: could not locate nas.mod '
                  f'signature in bank {nas_bank} -- symbolization will be '
                  f'unavailable, falling back to raw IP histogram only')
        else:
            print(f'[profile-f2] [{tag}] nas.mod load base = ${load_base:04X}  '
                  f'(bytecode range ${load_base:04X}-${load_base + seglen:04X}, '
                  f'{seglen} bytes)')

        # ---- the tight sampling loop ----
        bucket_hist = collections.Counter()
        raw_ip_hist = collections.Counter()
        off_cpu = 0
        total_samples = 0
        done = False
        i = 0
        while not done and total_samples < MAIN_LOOP_MAX_SAMPLES:
            # Jitter avoids phase-locking to a tight loop or scheduler tick.
            client.call_tool('step', {'cycles': rng.randrange(3500, 8500)})
            switches = client.call_tool('softswitches', {})
            regs = client.call_tool('regs', {})
            pc = regs['pc']
            if (switches.get('ramworks_bank') != nas_bank
                    or not switches.get('RAMRD')
                    or not switches.get('ALTZP') or pc >= 0xBF00):
                off_cpu += 1
            elif vm['DINTRP'] <= pc < vm['START'] or 0xEF <= pc <= 0xF8:
                y = regs['y']
                zp = client.call_tool('peek', {'addr': IPL_ADDR, 'count': 2,
                                                'bank': 'aux', 'aux_bank': nas_bank})['bytes']
                ipl, iph = zp[0], zp[1]
                ip = ((iph << 8) | ipl) + y
                raw_ip_hist[ip] += 1
                if load_base is not None:
                    off = ip - load_base
                    bucket = classify_offset(def_table, seglen, off)
                    if bucket is None:
                        bucket_hist['VM:rt/lib'] += 1
                    else:
                        bucket_hist['VM:' + bucket] += 1
            else:
                bucket = 'native:rt/lib/thunk'
                if load_base is not None:
                    for lo, hi, name in native:
                        if lo <= pc - load_base < hi:
                            bucket = 'native:' + name
                            break
                bucket_hist[bucket] += 1
            total_samples += 1
            i += 1
            if i % DONE_CHECK_PERIOD == 0:
                rows = screen_rows(client)
                if bare_prompt(rows):
                    done = True

        if not done:
            # tail-out: keep polling (cheaply) until the prompt genuinely
            # returns, matching the established methodology's own bound.
            wait_for(client, bare_prompt, f'{tag} prompt return (tail)', 400,
                     chunk_cycles=50_000)

        print(f'[profile-f2] [{tag}] {total_samples} samples '
              f'({off_cpu} off-cpu/kernel, {total_samples - off_cpu} on-process)')
        return {
            'tag': tag, 'total_samples': total_samples, 'off_cpu': off_cpu,
            'bucket_hist': bucket_hist, 'raw_ip_hist': raw_ip_hist,
            'load_base': load_base, 'seglen': seglen,
        }
    finally:
        client.close()


def report(result, def_table):
    tag = result['tag']
    on_cpu = result['total_samples'] - result['off_cpu']
    print()
    print(f'[profile-f2] ==================== {tag} ====================')
    print(f'[profile-f2] total samples: {result["total_samples"]}  '
          f'(on-process: {on_cpu}, off-cpu/kernel: {result["off_cpu"]})')

    if result['bucket_hist']:
        items = result['bucket_hist'].most_common()
        print(f'[profile-f2] symbolized histogram (of {on_cpu} on-process samples):')
        for name, cnt in items:
            pct = 100.0 * cnt / on_cpu if on_cpu else 0.0
            print(f'[profile-f2]   {name:<20s} {cnt:6d}  {pct:5.1f}%')

        top_counts = [cnt for _, cnt in items]
        top1 = 100.0 * sum(top_counts[:1]) / on_cpu if on_cpu else 0.0
        top3 = 100.0 * sum(top_counts[:3]) / on_cpu if on_cpu else 0.0
        top10 = 100.0 * sum(top_counts[:10]) / on_cpu if on_cpu else 0.0
        print(f'[profile-f2] concentration: top-1={top1:.1f}%  top-3={top3:.1f}%  '
              f'top-10={top10:.1f}%  (of {len(items)} distinct buckets)')
    else:
        print('[profile-f2] no symbolized histogram (load base not found)')

    raw = result['raw_ip_hist']
    if raw:
        raw_total = sum(raw.values())
        raw_items = raw.most_common(20)
        print(f'[profile-f2] raw hot-IP histogram (top 20 of {len(raw)} '
              f'distinct IPs, {raw_total} total VM samples):')
        for ip, cnt in raw_items:
            pct = 100.0 * cnt / raw_total
            print(f'[profile-f2]   ${ip:04X}  {cnt:6d}  {pct:5.1f}%')
        raw_top_counts = [cnt for _, cnt in raw.most_common()]
        rtop1 = 100.0 * sum(raw_top_counts[:1]) / raw_total
        rtop3 = 100.0 * sum(raw_top_counts[:3]) / raw_total
        rtop10 = 100.0 * sum(raw_top_counts[:10]) / raw_total
        print(f'[profile-f2] raw-IP concentration: top-1={rtop1:.1f}%  '
              f'top-3={rtop3:.1f}%  top-10={rtop10:.1f}%')

        if result['load_base'] is not None:
            lo, hi = result['load_base'], result['load_base'] + result['seglen']
            in_range = sum(c for ip, c in raw.items() if lo <= ip < hi)
            print(f'[profile-f2] validation: {in_range}/{raw_total} '
                  f'({100.0*in_range/raw_total:.1f}%) of VM samples '
                  f'fall inside nas.mod\'s own range ${lo:04X}-${hi:04X} '
                  f'(the rest are rt/lib -- other modules\' bytecode)')
            observed_min = min(raw)
            observed_max = max(raw)
            print(f'[profile-f2] observed IP range: ${observed_min:04X}-'
                  f'${observed_max:04X}')


def main():
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(DISK):
        print(f'error: missing {DISK} (run `make profile-image` first)',
              file=sys.stderr)
        return 2

    def_table, seglen = build_def_table()

    results = []
    for tag, srcname, objname in FIXTURES:
        r = run_fixture(tag, srcname, objname, def_table, seglen)
        results.append(r)
        report(r, def_table)

    print()
    print('[profile-f2] ==================== SUMMARY ====================')
    for r in results:
        on_cpu = r['total_samples'] - r['off_cpu']
        if r['bucket_hist']:
            top_name, top_cnt = r['bucket_hist'].most_common(1)[0]
            pct = 100.0 * top_cnt / on_cpu if on_cpu else 0.0
            print(f'[profile-f2] {r["tag"]}: {on_cpu} on-process samples, '
                  f'hottest bucket = {top_name} ({pct:.1f}%)')
        else:
            print(f'[profile-f2] {r["tag"]}: {on_cpu} on-process samples, '
                  f'unsymbolized (see raw histogram above)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
