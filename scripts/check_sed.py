#!/usr/bin/env python3
"""Boot and verify the ProDOS-hosted `sed` acceptance gate (`make
check-sed`). Companion to src/test/sedtest.s / sedtestb.s /
scripts/build_sed_image.py.

THE ORACLE IS THE HOST'S OWN sed (docs/E2E.md sec 4, stage 1): runs
1-7 and the differential halves of 10-11 come from
build_sed_image.compute_expected(), which runs the identical scripts
-- staged as BARE operands, the exact form maux receives -- through
the host reference on identical input and translates text
conventions. Nothing here was authored as an expected byte string,
and nothing may ever be captured from a maux run. Runs 8-9 and the
maux halves of 10-11 are named-divergence invariants (E2E.md oracle
3) -- see DIVERGENCE below.

THE POISON, in BOTH layers (learning:01M0M9R7RT22JEPP2R0Y6J9MBX's
method; check_ls.py the exemplar for the second):

  1. PRE-BOOT: liba's arena AND sed's own (LIBA_ZPG..SED_BSSEND,
     both ends from merlin32's own symbol table, never hardcoded)
     are $A5-filled in every candidate child bank. The kernel zeroes
     the first 256 bytes of the span at spawn (BC_ZPG_LEN, the
     read-before-write page), so the EFFECTIVE poisoned window is
     span-256 bytes.
  2. BETWEEN RUNS: every run after the first executes WARM in run
     1's bank (lazy free prefers the tagged bank), so the pre-boot
     poison is consumed by run 1 -- adversarial review N3. The
     parent parks on the R_GO handshake between every pair of runs
     and this gate re-scribbles the just-freed bank before releasing
     it, so ALL eleven runs face $A5, not just the first.

Vacuity guards: a pid IS its bank, so every run's pid must land in
the poisoned range; every gap must actually be serviced and its
poison read back; every run must reuse ONE bank (otherwise the
between-run poison went somewhere the next run never touched); and
the kernel's own LZ_WARM flag must be set at the end (the last spawn
really was served from a retained bank).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import arena  # noqa: E402 -- private-tree listings
import build_sed_image as bs  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'sed.po')

POISON = 0xA5
CAND_BANKS = range(2, 10)
NRUNS = 11

# ---------------------------------------------------------------------
# THE DIVERGENCE REGISTRY (docs/E2E.md sec 4: divergence from the host
# reference is a ratchet, PER ENTRY, WITH A REASON -- "a blanket 'we
# differ' is where every real bug hides"). Every deliberate difference
# between maux sed and the host reference is a named row; an
# unexplained difference is a FAILURE, not a diff to eyeball. Rows
# marked (asserted by run N) are exercised by this gate; the rest are
# scope statements from src/bin/sed.s's own header, listed so the next
# case author knows they are decisions with names, not oversights.
# ---------------------------------------------------------------------
DIVERGENCE = {
    ('sed', 'text convention'):
        'maux text is high-bit ASCII with CR line ends; the host '
        'reference output is translated byte-for-byte before compare '
        '(build_sed_image.to_maux). Not a behavior difference.',
    ('sed', 'final line without terminator gains a CR '
            '(asserted by run 10)'):
        'PRINTLINE always appends $8D, so an input whose last line '
        'lacks a terminator gains one where the host preserves the '
        'absence. Deliberate: a maux text file is CR-terminated by '
        'convention and every downstream consumer assumes it. The '
        'expectation is the translated host output PLUS the CR.',
    ('sed', 'pattern space cap PSMAX=2047, LOUD (asserted by run 11)'):
        'a pattern space grown past PSMAX by s, N, G or H is "sed: '
        'pattern space overflow", exit 2 -- never silent truncation. '
        'The host grows without bound; run 11 grows line 1 to 9000 '
        'chars, so maux prints nothing and refuses.',
    ('sed', 'input lines truncate at 255 (declared, unasserted)'):
        'lines longer than LINEMAX are truncated at the limit and '
        'the remainder discarded to the next CR -- grep.s\'s '
        'documented rule, same buffer argument. The pattern space '
        'itself holds PSMAX; only the READ window is 255.',
    ('sed', 'open-failure text and status (asserted by run 8)'):
        'message text is implementation-defined; maux prints '
        '"sed: cannot open <name>" (grep.s\'s convention) and exits 2. '
        'Host seds also exit nonzero; only the BYTES differ, so the '
        'run is an invariant, not a differential.',
    ('sed', 'unknown command refused (asserted by run 9)'):
        '`k` is no sed command anywhere; maux refuses LOUDLY ("sed: '
        'unknown command near char N", exit 2). Host seds refuse too '
        '(exit 1, their own wording); only the BYTES differ. Every '
        'POSIX command is implemented now, so an unknown letter is '
        'the only refusal left to assert.',
    ('sed', 'command count cap 48'):
        'SED_MAXCMD -- fixed compiled-command arrays in a 64K bank; '
        'the 49th command is a loud bad-script, never a silent drop. '
        'Likewise 16 labels, 4 distinct w files, 16 queued a/r per '
        'cycle, a 2048-byte script -- each its own loud message.',
    ('sed', 's///Ng: the Nth and every later match (GNU)'):
        'POSIX leaves g with a number unspecified; GNU replaces the '
        'Nth and every later match, BSD refuses the combination. maux '
        'takes GNU\'s reading (cheap utility, no bug caught by '
        'refusing -- docs/ANACHRONISMS.md\'s period-fidelity rule).',
    ('sed', 'N with no next line: no autoprint (POSIX, BSD)'):
        'POSIX: "quit without starting a new cycle or copying the '
        'pattern space to standard output". This host\'s BSD sed '
        'agrees; GNU prints the space. The portable idiom is $!N.',
    ('sed', 'labels end at ; as well as newline (GNU)'):
        'POSIX and BSD read a b/t/: label to the end of the line; '
        'GNU also stops at ;. maux stops at ; (a label with a '
        'semicolon in it is nothing anyone types). Portable scripts '
        'put labels on their own lines and the suite does.',
    ('sed', 'a/i/c one-line text accepted (GNU)'):
        '`1a text` is taken as a one-line text (leading blanks '
        'dropped; `a\\text` keeps them) alongside the POSIX `a\\` + '
        'newline form. BSD refuses the one-liner.',
    ('sed', 'q takes an exit code (POSIX.1-2024, GNU)'):
        '`q5` exits 5. BSD refuses the digits.',
    ('sed', 'l folds at 70 columns, newline shown as \\n'):
        'the fold width is implementation-defined; maux uses GNU\'s '
        'default (no row past 69 chars + \\). An embedded newline is '
        'written \\n (GNU; this host\'s BSD writes $ and a line '
        'break), and a literal backslash \\\\ (POSIX and GNU; this '
        'host\'s BSD writes a bare \\ -- found by check_posixsed\'s '
        'first BSD run). The suite oracles l under COLUMNS=70, where '
        'BSD folds identically, and keeps the backslash case GNU-only.',
    ('sed', 'regex: POSIX BRE (C locale), and \\n is the newline'):
        'liba/regex.s is POSIX BRE as of W5d (docs/ANACHRONISMS.md): '
        'groups, backrefs, intervals, the twelve [[:class:]] names, '
        '[=c=] and [.c.] as single characters, leftmost-longest over '
        'the whole match when a group is present. Not claimed: the '
        'per-subexpression capture rules for equal-length matches. '
        '\\n in an RE (and [\\n]) matches the pattern space\'s '
        'embedded newline, POSIX sed\'s rule; GNU agrees, this '
        'host\'s BSD reads [\\n] as backslash-or-n. Shared engine, '
        'so ed/ex/vi/grep read \\n the same way (GNU ed does too).',
}

R_STATUS0   = 0x14B0
R_SPWNPID0  = 0x14C0
R_WAITPID0  = 0x14D0
R_TRANS0    = 0x14E0
R_ERRTRNS0  = 0x1500
R_DONE      = 0x1518
R_ERR       = 0x1519
R_STEP      = 0x151A
R_GO_REQ    = 0x151B
R_GO        = 0x151C
R_DATA0     = 0x1600      # + n*128
R_ERRDATA0  = 0x1C00      # + n*64

LABELS = ['s/alpha/beta/', '-n /ell/p', 's/l*/X/g (null-match rule)',
          '2,3d', 's/gamma/[&]/;s/l/L/2', '-n $p two files', 'q',
          'open failure', 'bad script (k)',
          'no final newline', 'pattern space overflow']


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def peek_bank(client, bank, addr, count):
    return client.call_tool('peek', {
        'addr': addr, 'count': count, 'bank': 'aux', 'aux_bank': bank,
    })['bytes']


def peek_u16(client, addr):
    b = peek_aux1(client, addr, 2)
    return b[0] | (b[1] << 8)


def sed_arena():
    """(first byte, length) of sed's liba+own `dum` arena, from
    merlin32 -v1's symbol dump -- check_ls.py's technique, never
    hardcoded (learning:01M0M9R7RT22JEPP2R0Y6J9MBX)."""
    lines = arena.private_listing('src/bin', 'sed.s',
                                  'sed.bin_Output.txt')
    syms = {}
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    missing = [w for w in ('LIBA_ZPG', 'SED_BSSEND') if w not in syms]
    if missing:
        raise RuntimeError(
            f'{missing} absent from sed.bin_Output.txt -- has the '
            f'sec-21 layout (libabss.s put last, SED_BSSEND at the '
            f'arena end) changed?')
    return (syms['LIBA_ZPG'], syms['SED_BSSEND'] - syms['LIBA_ZPG'])


def kernel_symbol(name):
    """Address of a MAIN-memory kernel cell in the sedtest image --
    check_ls.py's technique: assemble the manifest with -v1 in a
    private tree, read merlin32's own symbol dump. LZ_WARM moves whenever any
    kernel module's size does; a stale address reads an unrelated
    byte and passes or fails for no reason."""
    lines = arena.private_listing('src/test', 'sedtest.s',
                                  'MAUXSEDTEST.SYSTEM_Output.txt')
    addr = None
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            addr = int(m.group(2), 16)
    if addr is None:
        raise RuntimeError(f'{name} absent from the sedtest symbol dump')
    return addr


def poison_arena(client, bank, arena, span):
    client.call_tool('poke', {
        'addr': arena, 'bytes': [POISON] * span,
        'bank': 'aux', 'aux_bank': bank,
    })


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make sed-image first',
              file=sys.stderr)
        return 2

    expected = bs.compute_expected(disk)

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-sed] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-sed] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # -- LAYER 1: the pre-boot poison (this file's header).
        arena, span = sed_arena()
        print(f'[check-sed] poisoning liba+sed arenas ${arena:04X}+{span} '
              f'(effective {span - 256} past the kernel-zeroed page) '
              f'with ${POISON:02X} in aux banks {CAND_BANKS.start}-'
              f'{CAND_BANKS.stop - 1}', file=sys.stderr)
        for bank in CAND_BANKS:
            poison_arena(client, bank, arena, span)
            back = peek_bank(client, bank, arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'poison poke into bank {bank} read back {back} -- '
                    f'it did not land, the run would prove nothing')

        warm_addr = kernel_symbol('LZ_WARM')

        # -- LAYER 2: the between-run poison. sedtestb.s publishes the
        # gap number in R_GO_REQ after each run and parks until R_GO
        # matches, so the scribble lands strictly between one run's
        # reap and the next one's spawn.
        served = {}
        failed_poison = []
        done = 0
        for i in range(2000):
            client.call_tool('step', {'cycles': 200_000})
            req = peek_aux1(client, R_GO_REQ)[0]
            if 1 <= req < NRUNS and req not in served:
                bank = peek_aux1(client, R_WAITPID0 + req - 1)[0]
                poison_arena(client, bank, arena, span)
                back = peek_bank(client, bank, arena, 8)
                if any(b != POISON for b in back):
                    failed_poison.append((req, bank, back))
                served[req] = bank
                client.call_tool('poke', {
                    'addr': R_GO, 'bytes': [req],
                    'bank': 'aux', 'aux_bank': 1,
                })
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        warm = client.call_tool('peek', {
            'addr': warm_addr, 'count': 1, 'bank': 'main'})['bytes'][0]
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]

        status = list(peek_aux1(client, R_STATUS0, NRUNS))
        spawn_pid = list(peek_aux1(client, R_SPWNPID0, NRUNS))
        wait_pid = list(peek_aux1(client, R_WAITPID0, NRUNS))
        trans = [peek_u16(client, R_TRANS0 + 2 * i) for i in range(NRUNS)]
        err_trans = [peek_u16(client, R_ERRTRNS0 + 2 * i)
                     for i in range(NRUNS)]
        data = [bytes(peek_aux1(client, R_DATA0 + 128 * i, trans[i]))
                if trans[i] else b'' for i in range(NRUNS)]
        errdata = [bytes(peek_aux1(client, R_ERRDATA0 + 64 * i,
                                   err_trans[i]))
                   if err_trans[i] else b'' for i in range(NRUNS)]

        print(f'[check-sed] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} status={status} spawn_pid={spawn_pid} '
              f'wait_pid={wait_pid} trans={trans} err_trans={err_trans} '
              f'poisoned={served} LZ_WARM=${warm:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, '
                            f'step=${step:02X})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        for i in range(NRUNS):
            if spawn_pid[i] == 0:
                failures.append(f'run {i+1}: SPAWN(SED) returned pid 0')
            if wait_pid[i] != spawn_pid[i]:
                failures.append(f'run {i+1}: wait pid {wait_pid[i]} != '
                                f'spawn pid {spawn_pid[i]}')
            # -- VACUITY GUARD for the poison: a pid IS its bank.
            if spawn_pid[i] and spawn_pid[i] not in CAND_BANKS:
                failures.append(
                    f'run {i+1}: child pid/bank {spawn_pid[i]} is outside '
                    f'the poisoned range {CAND_BANKS.start}-'
                    f'{CAND_BANKS.stop - 1}, so this run did not exercise '
                    f'sed\'s uncleared arena at all. Widen CAND_BANKS.')

        # -- THE BETWEEN-RUN POISON'S OWN GUARDS (check_ls.py's set) --
        if sorted(served) != list(range(1, NRUNS)):
            failures.append(f'expected to service handshake gaps '
                            f'1-{NRUNS-1}, serviced {sorted(served)} -- '
                            f'the poison did not land between every pair '
                            f'of runs')
        for gap, bank, back in failed_poison:
            failures.append(f'gap {gap}: the ${POISON:02X} poke into bank '
                            f'{bank} read back {back} -- the poison did '
                            f'not land, so the run after it proved nothing')
        for gap, bank in served.items():
            if bank != spawn_pid[gap]:
                failures.append(f'gap {gap}: poisoned bank {bank} but run '
                                f'{gap+1} ran in bank {spawn_pid[gap]}')
        if len(set(spawn_pid)) != 1:
            failures.append(
                f'runs did not share one bank ({spawn_pid}) -- a pid IS '
                f'its bank, so the retained bank was NOT reused and the '
                f'between-run poison went somewhere the next run never '
                f'touched. The gate is vacuous in that state.')
        if not warm:
            failures.append(
                'LZ_WARM is clear after the final run -- the kernel says '
                'the last spawn was NOT served from a retained bank, so '
                'the between-run poison never met a warm respawn at all')

        for i in range(NRUNS):
            n = i + 1
            label = LABELS[i]
            exp_out = expected[f'run{n}']
            exp_err = expected[f'run{n}_err']
            exp_st = expected[f'run{n}_status']
            if status[i] != exp_st:
                failures.append(f'run {n} ({label}): exit status expected '
                                f'{exp_st}, got {status[i]}')
            if trans[i] != len(exp_out):
                failures.append(f'run {n} ({label}): stdout trans_count '
                                f'expected {len(exp_out)}, got {trans[i]}')
            if data[i] != exp_out:
                failures.append(f'run {n} ({label}) stdout mismatch '
                                f'(the host reference is the oracle -- an '
                                f'unexplained difference is a FAILURE, '
                                f'docs/E2E.md sec 4):\n'
                                f'  expected={exp_out!r}\n'
                                f'  got     ={data[i]!r}')
            if err_trans[i] != len(exp_err):
                failures.append(f'run {n} ({label}): stderr trans_count '
                                f'expected {len(exp_err)}, got '
                                f'{err_trans[i]}')
            if errdata[i] != exp_err:
                failures.append(f'run {n} ({label}) stderr mismatch:\n'
                                f'  expected={exp_err!r}\n'
                                f'  got     ={errdata[i]!r}')

        if failures:
            for failure in failures:
                print(f'[check-sed] FAIL: {failure}', file=sys.stderr)
            return 1

        print(f'[check-sed] PASS: sed -- {len(LABELS)} runs: 1-7 and the '
              f'differential halves of 10-11 byte-exact against the host '
              f'reference (bare-operand invocation, translated -- no '
              f'authored expectations), plus the named-divergence '
              f'invariants (open failure; `k` refused; the final-line CR; '
              f'the loud pattern-space cap). Arena '
              f'${arena:04X}+{span} (effective {span - 256}) poisoned '
              f'${POISON:02X} pre-boot in banks {CAND_BANKS.start}-'
              f'{CAND_BANKS.stop - 1} AND re-scribbled in all '
              f'{NRUNS - 1} gaps into bank {spawn_pid[0]}, which every '
              f'run reused (LZ_WARM set). {len(DIVERGENCE)} divergence '
              f'entries, each with a reason.')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
