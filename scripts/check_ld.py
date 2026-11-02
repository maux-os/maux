#!/usr/bin/env python3
"""Boot and verify the `ld` acceptance gate (`make check-ld`).

Companion to src/test/ldtest.s / ldtestb.s / scripts/build_ld_image.py.
See docs/LD-DESIGN.md section 0 for the bar this proves: `ld [-o outfile]
module.rel ...` runs INSIDE maux and links the SAME two modules
scripts/check_rel.py already pins (RTLIB, RTMAIN) into an output
byte-identical to the SAME link performed by the stock toolchain
(build/rtlinked.bin, produced by build_ld_image.py booting real Merlin-8
under verilogapple -- LINK has no host-side merlin32 equivalent).

Three runs (ldtestb.s's PARENT_PROC):
  1. `sh` (stdin redirected from a staged script) runs
     `LD -o /mnt/MAUX/LDOUT /mnt/MAUX/RTMAIN /mnt/MAUX/RTLIB` then `EXIT` -- the
     "runs from the maux shell" proof. LDOUT is read back and compared
     byte-for-byte against build/rtlinked.bin.
  2. THE SAME LINK AGAIN, adjacently, into /mnt/MAUX/LDOUT2, and compared
     against the SAME stock reference. See below.
  3. `LD` spawned DIRECTLY (sh has no `2>` stderr redirection) on a
     missing module (/mnt/MAUX/NOSUCH, which the image deliberately does
     NOT stage) -- docs/LD-DESIGN.md section 0's own "a deliberate
     failure (missing module) exiting nonzero with an `ld:` diagnostic"
     requirement. fd 2 dup'd to a harness-owned file, same technique
     check_as.py already uses.

WHY RUN 2 EXISTS (docs/STICKY.md sec 31). Until 2026-08-23 this gate
linked exactly ONCE per boot, and that is the only reason it stayed
green through the defect sec 29 measured: lazy free (sec 27) retains a
dead process's bank and serves the next spawn of the same program out
of it without recopying the text, so `ld`'s SECOND invocation was the
first one running on its own leftovers. It died there --
`ld: internal: exit pad not found`, no output file -- and nothing in
the tree ran `ld` twice in one boot, so nothing noticed. A gate that
cannot observe a second invocation cannot see that class of bug at
all (learning:01M0MEKF0H8AVAXJG4PZ7P5QXC).

Run 2 is compared against the STOCK reference rather than against run
1, which is strictly stronger: two identically-wrong outputs would
still fail.

AND IT IS GUARDED AGAINST PASSING VACUOUSLY. If the second link were
served COLD -- because the bank was reclaimed between the two spawns,
or because someone made `ld`'s entry head move so LZ_RETAIN refuses to
retain it -- run 2 would prove nothing at all while still passing.
So the gate reads the kernel's own LZ_WARM, the flag the loader sets
when a spawn is served out of a retained bank, and fails if the boot
never took that path for `ld`.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from textaudit import load_syms  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'ld.po')
REF_BIN = os.path.join(ROOT, 'build', 'rtlinked.bin')
# The harness kernel this gate boots, and its merlin32 -v1 symbol dump
# -- load_syms refuses a dump older than the binary it describes
# (sec 29's own defect: a gate reading stale symbols does not fail, it
# lies).
SYS_BIN = os.path.join(ROOT, 'build', 'LDTEST.SYSTEM')
SYMFILE = SYS_BIN + '_Output.txt'
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_SCRIPT_FD  = 0x1200
R_SH_PID     = 0x1201
R_SH_WAIT    = 0x1202
R_SH_STATUS  = 0x1203
R_LDERR_FD   = 0x1204
R_LD_PID     = 0x1205
R_LD_WAIT    = 0x1206
R_LD_STATUS  = 0x1207
R_LDE_TRANS  = 0x1208
R_LDE_DATA   = 0x120A
RBLEN        = 80
R_DONE       = 0x1260
R_ERR        = 0x1261
R_STEP       = 0x1262


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr, 'count': count, 'bank': 'aux', 'aux_bank': 1,
    })['bytes']


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run `make ld-image` first',
              file=sys.stderr)
        return 2
    if not os.path.exists(REF_BIN):
        print(f'error: {REF_BIN} not found -- run `make ld-image` first '
              f'(build_ld_image.py produces it)', file=sys.stderr)
        return 2
    ref = open(REF_BIN, 'rb').read()
    # LDOUT3/4 and SYSOUT exist only for the NATIVE linker, which is
    # what `ld` now is; LD_UNDER_TEST=mld selects the Merlin bridge,
    # which has no library search. LDOUT3 is the same link, but with
    # RTLIB found through `-l c` in /usr/lib/LIBC instead of named
    # on the command line, alongside a DECOY member that declares no
    # ENT and so must be rejected. Same bytes or the search is
    # either not finding or not being selective.
    want_lib = os.environ.get('LD_UNDER_TEST', 'ld') != 'mld'
    syms = load_syms(SYMFILE, names=('LZ_WARM',), binary=SYS_BIN)

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-ld] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-ld] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        for _ in range(14000):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        ld_pid = peek_aux1(client, R_LD_PID)[0]
        ld_status = peek_aux1(client, R_LD_STATUS)[0]
        t = peek_aux1(client, R_LDE_TRANS, 2)
        lde_trans = t[0] | (t[1] << 8)
        lde_data = bytes(peek_aux1(client, R_LDE_DATA,
                                   min(lde_trans, RBLEN)))
        # LZ_WARM lives in MAIN memory (the kernel's own flag), not in
        # the harness's aux bank 1.
        warm = client.call_tool('peek', {
            'addr': syms['LZ_WARM'], 'count': 1, 'bank': 'main',
        })['bytes'][0]
        print(f'[check-ld] done=${done:02X} err=${err:02X} step=${step:02X}'
              f' sh_pid={sh_pid} sh_status=${sh_status:02X}'
              f' ld_pid={ld_pid} ld_status=${ld_status:02X}'
              f' lz_warm=${warm:02X}'
              f' lde_trans={lde_trans} lde_data={lde_data!r}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, '
                            f'step={step})')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if sh_status != 0:
            # sh's own EXIT builtin does not inspect the preceding
            # command's exit status (no $? -- SH-DESIGN's own v1 scope,
            # same note check_as.py already carries) -- this can only
            # catch sh/SPAWN/WAIT infrastructure failing, never an LD
            # link failure (that signal is the LDOUT byte-compare below).
            failures.append(f'sh exit status expected $00, got '
                            f'${sh_status:02X} (sh/SPAWN/WAIT '
                            f'infrastructure failure -- NOT necessarily '
                            f'an LD failure, see this file\'s own comment)')
        if ld_pid == 0:
            failures.append('direct SPAWN(LD) returned pid 0')
        if ld_status == 0:
            failures.append('LD on a missing module exited 0, expected '
                            'nonzero')
        if not lde_data.startswith(bytes([ord('l') | 0x80, ord('d') | 0x80,
                                          ord(':') | 0x80])):
            failures.append(f'LD stderr diagnostic missing the "ld: " '
                            f'prefix (high-bit-set): got {lde_data!r}')

        if failures:
            for f in failures:
                print(f'[check-ld] FAIL: {f}', file=sys.stderr)
            return 1

        vol = a2til.open_image(disk)
        cases = [('first', 'LDOUT'), ('SECOND', 'LDOUT2')]
        if want_lib:
            cases.append(('-l c library-search', 'LDOUT3'))
        for which, name in cases:
            try:
                got = bytes(vol.read_file(f'/mnt/{VOL}/{name}'))
            except FileNotFoundError:
                failures.append(
                    f'/mnt/{VOL}/{name} does not exist -- the {which} link '
                    f'wrote no output file at all')
                continue
            print(f'[check-ld] {name}: {len(got)}B on-image, {len(ref)}B '
                  f'stock reference ({which} link of this boot)')
            if got != ref:
                ndiff = sum(1 for x, y in zip(got, ref) if x != y)
                failures.append(
                    f'{name} -- the {which} link of this boot -- differs '
                    f'from the stock link in {ndiff} byte(s) (lengths '
                    f'{len(got)} vs {len(ref)})\n  got={got!r}\n  '
                    f'ref={ref!r}')
        if want_lib:
            # LDOUT4 -- a -L search path AND the fixpoint rescan. QA
            # satisfies RTMAIN and itself references QBSYM, so the
            # first sweep pulls QA and leaves QBSYM undefined; only a
            # SECOND sweep finds QB. A linker that scans each library
            # once fails this link outright rather than shortening it.
            #
            # PLACEMENT IS DIRECTORY ORDER, not discovery order (the
            # kernel-library contract, ldscan.s LIBSPLICE): QB was
            # CREATED first in LIBQ, so although only the rescan
            # takes it, it lands BEFORE QA in the image. RTMAIN jsr
            # LIBUSED=$2008 (QA), QB's nops at $2004, QA jsr
            # QBSYM=$2004.
            chain = bytes.fromhex('20082060eaeaea6020042060')
            try:
                got = bytes(vol.read_file(f'/mnt/{VOL}/LDOUT4'))
                if got != chain:
                    failures.append(
                        f'LDOUT4 (-L + fixpoint) is {got.hex()}, expected '
                        f'{chain.hex()} -- RTMAIN, then QB at $2004 '
                        f'(directory order), then QA at $2008; QB is '
                        f'pulled in by the RESCAN')
                else:
                    print(f'[check-ld] LDOUT4: {len(got)}B, -L path and '
                          f'the fixpoint rescan both exercised')
            except FileNotFoundError:
                failures.append(
                    '/mnt/MAUX/LDOUT4 does not exist -- the -L / fixpoint '
                    'link wrote nothing. If the rescan never runs, QBSYM '
                    'stays undefined and the link fails here.')
            # SYSOUT -- a ProDOS SYSTEM file. Same bytes as the stock
            # reference, but type $FF and aux $2000: what ProDOS's own
            # system loader requires, which is the whole point of -t.
            try:
                ent = vol.entry_for(f'/mnt/{VOL}/SYSOUT')
                got = bytes(vol.read_file(f'/mnt/{VOL}/SYSOUT'))
                if got != ref:
                    failures.append('SYSOUT differs from the stock link')
                elif ent.type != 0xFF or ent.aux_type != 0x2000:
                    failures.append(
                        f'SYSOUT is type ${ent.type:02X} aux '
                        f'${ent.aux_type:04X}, expected $FF/$2000 -- a '
                        f'.SYSTEM file ProDOS will not load is not one')
                else:
                    print(f'[check-ld] SYSOUT: {len(got)}B, type $FF aux '
                          f'$2000 -- a loadable .SYSTEM file')
            except FileNotFoundError:
                failures.append('/mnt/MAUX/SYSOUT does not exist -- `-t FF` '
                                'wrote no output')
            # `-l zzz` names a library that exists under no search
            # path. It must REFUSE -- writing RTMAIN alone would leave
            # LIBUSED dangling in a file that looks like a link.
            try:
                vol.read_file(f'/mnt/{VOL}/NOLIB')
                failures.append(
                    '/mnt/MAUX/NOLIB EXISTS -- `-l zzz` names a library '
                    'under no search path, so the link must fail. '
                    'Writing the output anyway leaves LIBUSED '
                    'unresolved in a file that looks linked.')
            except FileNotFoundError:
                print('[check-ld] NOLIB: absent, as it must be -- '
                      '`-l` on a missing library refuses')
            # LDOUT5/LDOUT6 -- -L resolving an EXPLICIT MODULE
            # OPERAND (ONLYL), not a -l library member. ONLYL exists
            # ONLY under /mnt/MAUX/MYMOD, unreachable any other way a
            # bare operand resolves, so LDOUT5 existing proves -L's
            # search actually ran (via its attached form,
            # -L/mnt/MAUX/MYMOD), and LDOUT6's ABSENCE -- same bare
            # name, -L omitted -- is the teeth: nothing else on this
            # disk could have made that run succeed.
            try:
                got = bytes(vol.read_file(f'/mnt/{VOL}/LDOUT5'))
                if len(got) != len(ref) - 4:
                    # ref is RTMAIN(4B)+RTLIB(68B); ONLYL alone is
                    # just RTLIB's bytes, so LDOUT5 should be exactly
                    # 68B -- a length check, not a stock byte-compare
                    # (there is no stock reference for this pairing).
                    failures.append(
                        f'LDOUT5 (-L module resolution) is {len(got)}B, '
                        f'expected {len(ref) - 4}B (RTLIB alone, no '
                        f'RTMAIN in this link)')
                else:
                    print(f'[check-ld] LDOUT5: {len(got)}B -- bare '
                          f'"ONLYL" resolved via -L/mnt/MAUX/MYMOD '
                          f'(attached form)')
            except FileNotFoundError:
                failures.append(
                    '/mnt/MAUX/LDOUT5 does not exist -- bare "ONLYL" with '
                    '-L/mnt/MAUX/MYMOD should have resolved and linked; '
                    'if -L stopped resolving explicit module operands, '
                    'this is silent everywhere else')
            try:
                vol.read_file(f'/mnt/{VOL}/LDOUT6')
                failures.append(
                    '/mnt/MAUX/LDOUT6 EXISTS -- bare "ONLYL" with NO -L '
                    'given should be unresolvable (it lives only under '
                    '/mnt/MAUX/MYMOD) and the link must refuse. If this '
                    'exists, either -L is being consulted when it was '
                    'not given, or ONLYL is reachable some other way '
                    'that would make LDOUT5 prove nothing.')
            except FileNotFoundError:
                print('[check-ld] LDOUT6: absent, as it must be -- the '
                      'SAME bare module with -L omitted refuses, which '
                      'is what makes LDOUT5 real teeth and not a '
                      'coincidence')
            # LDOUT7/LDOUT8 -- ARGUMENT FILES (KFIX3 item 0,
            # src/bin/ldargf.s). LDOUT7 is LDOUT's own link with the
            # whole word list in a file (`LD @/mnt/MAUX/LDARGS`, a
            # low-ASCII TXT file on two lines, the form the self-host
            # staging writes) and must equal the stock link byte for
            # byte -- the proof the planner's long link lines
            # (sh, vi, more ...) rest on. LDOUT8 is the same link
            # with a word AFTER `@FILE`: ld refuses it, so it must
            # not exist; a reader that ignored the extra word would
            # have linked it.
            try:
                got = bytes(vol.read_file(f'/mnt/{VOL}/LDOUT7'))
                if got != ref:
                    ndiff = sum(1 for a, b in zip(got, ref) if a != b)
                    failures.append(
                        f'LDOUT7 (`ld @FILE`) differs from the stock '
                        f'link in {ndiff} byte(s) (lengths {len(got)} '
                        f'vs {len(ref)})')
                else:
                    print(f'[check-ld] LDOUT7: {len(got)}B -- `ld '
                          f'@FILE` linked byte-identically to the '
                          f'stock link')
            except FileNotFoundError:
                failures.append(
                    '/mnt/MAUX/LDOUT7 does not exist -- `ld @FILE` '
                    'wrote nothing (the argument file was not read)')
            # LDOUT9/10/11 -- THE LENGTH BOUNDARY (review F6). ld reads
            # ARGFLIM (1,023) bytes and refuses a read that fills it,
            # so the longest argument file is 1,022 B: LDOUT9 (exactly
            # that, its last word ending on the buffer's last byte
            # with no line end) must equal the stock link, LDOUT10
            # (one blank more) must not exist, and LDOUT11 (a short
            # file, last word unterminated) must link.
            for name, want_made, why in (
                    ('LDOUT9', True, 'a 1,022-byte argument file'),
                    ('LDOUT10', False, 'a 1,023-byte argument file'),
                    ('LDOUT11', True, 'an unterminated last word')):
                try:
                    got = bytes(vol.read_file(f'/mnt/{VOL}/{name}'))
                except FileNotFoundError:
                    got = None
                if want_made and got != ref:
                    failures.append(
                        f'{name} ({why}) '
                        f'{"does not exist" if got is None else "differs from the stock link"}'
                        f' -- `ld @FILE` must accept it')
                elif not want_made and got is not None:
                    failures.append(
                        f'{name} EXISTS -- {why} fills ld\'s buffer and '
                        f'must be refused, not truncated')
                else:
                    print(f'[check-ld] {name}: '
                          f'{"linked byte-identically" if want_made else "absent, as it must be"}'
                          f' ({why})')
            try:
                vol.read_file(f'/mnt/{VOL}/LDOUT8')
                failures.append(
                    '/mnt/MAUX/LDOUT8 EXISTS -- `ld @FILE -z` must be '
                    'refused (nothing may follow @FILE); the extra '
                    'word was ignored instead')
            except FileNotFoundError:
                print('[check-ld] LDOUT8: absent, as it must be -- a '
                      'word after `@FILE` is refused')

        # VACUITY, checked AFTER the byte comparisons so a red run
        # reports both halves. LZ_WARM is the loader's own "this spawn
        # was served out of a retained bank" flag and it survives until
        # the NEXT spawn, so at the end of the boot it describes run 3
        # (the direct `LD`) -- which can only be warm if the bank has
        # been passing down the chain from run 1. Clear means no `ld`
        # spawn in this boot took the no-copy path at all, and the
        # repeat link then proved nothing it was added to prove.
        # check-textaudit's own `ld` pair carries the per-exit version
        # of this assertion (it reads LZ_WARM at each LZ_RETAIN); this
        # is the cheap corroboration that keeps THIS gate honest.
        if warm == 0:
            failures.append(
                'the kernel\'s LZ_WARM is clear: no `ld` spawn in this '
                'boot was served out of a retained bank, so the repeat '
                'link ran on a freshly copied image and proved nothing '
                'about warm respawn. Either lazy free stopped retaining '
                '`ld` (did its entry head start moving?) or something '
                'reclaimed the bank between the spawns.')

        if failures:
            for f in failures:
                print(f'[check-ld] FAIL: {f}', file=sys.stderr)
            return 1

        print('[check-ld] PASS: `ld` (spawned from the maux shell via sh) '
              'links RTMAIN+RTLIB to a BYTE-IDENTICAL image against the '
              'stock toolchain\'s own LINK -- TWICE in one boot, the '
              'second time served warm out of the bank the first left '
              'behind -- and a missing module (direct spawn, fd 2 '
              'captured) exits nonzero with an "ld: "-prefixed diagnostic')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
