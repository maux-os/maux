#!/usr/bin/env python3
"""check_mount.py -- `mount`, `umount`, `/mnt` and `..` on the virtual
root (`make check-mount`, docs/VROOT.md "`mount` and `umount`").

Boots the play image (unit 1, volume MAUX), a ProDOS volume SECOND (unit
2: /F and an empty /SUB) and a ProDOS FLOPPY.DISK.ABC on slot 6 holding
/HELLO ("HI"; the name is 15 characters, ProDOS's longest, and rows 3 and
9 reach the volume by it), written fresh into a temp dir by a2til.  Everything is typed at
the shell and judged off the screen, the check_devfs.py idiom (its
helpers are imported, not copied).

Rows, in order (each is one `assert`, none is skipped on an earlier red):

  1. NEVER POLL.  `ls -1 /mnt` lists MAUX and SECOND only -- no FLOPPY.DISK.ABC --
     and `mount` prints exactly
         /dev/s7d1 on /mnt/MAUX
         /dev/s7d2 on /mnt/SECOND
     (the listing bytes, hand-written; the BOOT volume first, then
     ascending slot and drive -- operator 2026-10-11 "yes sort it";
     before that it was DEVLST order, the last unit found first),
     while the Disk II has not moved one bit
     (`disk2_state.bit_pos` == 0: the drive never spun).
  2. `mount /dev/s6d1` prints nothing, exits 0, and the drive spun for
     ONE on-line: 0 < bit_pos <= ONE_ONLINE_MAX.  A second ON_LINE adds
     about 300,000 bits (measured, printed), so the bound proves one.
  3. `/mnt` now lists FLOPPY.DISK.ABC by NAME, `mount` shows
     `/dev/s6d1 on /mnt/FLOPPY.DISK.ABC`, `ls /mnt/FLOPPY.DISK.ABC` is HELLO and `cat` of
     it is HI.
  4. BUSY.  With a cwd on /mnt/FLOPPY.DISK.ABC `umount /mnt/FLOPPY.DISK.ABC` is refused
     (exit 1, `umount: /mnt/FLOPPY.DISK.ABC: busy`) and FLOPPY.DISK.ABC stays listed.
     `umount /dev/s6d1` is refused for the same reason.
  5. After `cd /` the same umount succeeds (exit 0, silent) after at
     most ONE on-line (it maps the name to its unit, the user having
     named the volume), `/mnt` and `mount` are MAUX and SECOND again,
     and the listings after it move the drive by ZERO bits.
  6. REFUSALS.  `umount /mnt/MAUX` (the boot volume), `umount
     /mnt/SECOND` (a fast unit is always mounted: `not a mountable
     unit`), `mount /dev/s5d1` (`no device connected`, MLI $28) and
     `mount /dev/nope` each exit 1 with that exact diagnostic and
     change nothing; `mount /dev/s7d1` (a fast unit) is a successful no-op.
  7. `..`, always as `cd X` then `cd ..` so a failed `cd ..` cannot
     pass by leaving the cwd where the answer happens to be:
         X = /bin, /mnt, /dev          -> /
         X = /mnt/MAUX                 -> /mnt/
         X = /mnt/SECOND/SUB           -> /mnt/SECOND/, then /mnt/, then /
         X = /mnt/MAUX/BIN             -> pwd is /bin/ (one canonical
               name for a map target, docs/VROOT-NOTES.md M4), then /
     and through `find`: from /mnt/SECOND/SUB, `find ..` lists `..`,
     `../F` and `../SUB`, the parent's own children, not the volume
     root's.  An `..` EMBEDDED in an absolute path (`/mnt/MAUX/..`) is
     not resolved by anything, as on the base build: ProDOS rejects it.

  8. `/` is a table: `touch /X`, `mkdir /D`, `rmdir /mnt` and `rm /bin`
     each exit 1 and `ls -1 /` is still the six rows.

  9. `/mnt/NAME` NAMES A VOLUME THE MACHINE HAS (KFIX5, docs/KFIX5.md
     item 2).  With the floppy unmounted, `ls /mnt/GONE`, `cat
     /mnt/GONE/x`, `echo q > /mnt/GONE/x`, `cd /mnt/GONE`, `test -d
     /mnt/GONE` and `ls /mnt/FLOPPY.DISK.ABC` each fail (exit 1) with ALL FOUR
     Disk II fields (motor_on, track, quarter_track, bit_pos) exactly
     as they were: the kernel refuses the name before the MLI's volume
     search, which ON_LINEs every drive.  A name of 16 characters
     is refused too.  The boot volume (any case) and the fast unit's
     SECOND stay reachable with the drive still; after `mount
     /dev/s6d1` /mnt/FLOPPY.DISK.ABC is reachable (HELLO), and after `umount
     /dev/s6d1` it is refused again without a spin.  (The loop-mounted
     volume stays reachable: check-loop's /mnt/LOOPVOL, /mnt/ONFLOP and
     /mnt/BIGVOL rows.)

Teeth: `--play build-of-main/play.po` runs the same script against a
build that has no virtual root and no `mount`; every row above must read
red there.  Shown on cba54c5 in docs/VROOT-NOTES.md.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_devfs as D  # noqa: E402
import gate_race as GR  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: bits the Disk II head passes under the read gate for ONE ON_LINE,
#: first spin-up included (measured 429,342; a second, warm ON_LINE
#: adds about 300,000 -- docs/VROOT-NOTES.md).
ONE_ONLINE_MAX = 560_000

#: a WARM ON_LINE (motor already up to speed is not assumed: this is the
#: cold figure of a second ON_LINE, measured 300,863 bits).
ONE_WARM_MAX = 440_000


def make_volumes(tmp):
    flop = os.path.join(tmp, 'flop.po')
    prodos.create(flop, name='FLOPPY.DISK.ABC', blocks=280)
    v = prodos.Volume(flop)
    v.write_file('/HELLO', b'\xc8\xc9\x8d', file_type=4, aux_type=0)
    v.close()
    second = os.path.join(tmp, 'second.po')
    prodos.create(second, name='SECOND', blocks=280)
    v = prodos.Volume(second)
    v.mkdir('/SUB')
    v.write_file('/F', b'\xd8\x8d', file_type=4, aux_type=0)
    v.close()
    return flop, second


def mount_all(client, boot, second, flop):
    """check_devfs.mount_family with a .po-ordered floppy.  Slot 6
    FIRST: a slot-6 mount cold-resets the machine."""
    r = client.call_tool('mount_disk', {'path': flop, 'slot': 6,
                                        'order': 'po'})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk(floppy) failed: {r}')
    for path, unit in ((boot, 1), (second, 2)):
        r = client.call_tool('mount_disk', {'path': path, 'unit': unit})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk(unit {unit}) failed: {r}')
    for addr, val in ((D.PT_F40_ADDR, D.PT_F40_MAG1),
                      (D.PT_F40B_ADDR, D.PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                  'bank': 'main'})
    D.wait_for_screen(client, D.prompt_ready, 'shell prompt')


def settle(client):
    """Step until the Disk II motor is off and spun down, twice in a
    row: bit_pos keeps advancing for ~1 s after the last access, and a
    sample taken mid-spindown reads as an access that never happened."""
    quiet = 0
    for _ in GR.polls(client, 400, 500_000):
        d = client.call_tool('disk2_state', {})
        if not d.get('motor_on') and not d.get('spindown_cycles'):
            quiet += 1
            if quiet == 2:
                return
        else:
            quiet = 0
    raise RuntimeError('Disk II never settled')


def job_alive(client, row):
    """Is the background job a shell printed as `[n] pid` still a live
    process (RUNNABLE/RUNNING/BLOCKED)? The overlap a row needs -- an
    object held OPEN by a job -- is a property of that job, readable
    from its PCB (annex bank 0, 16 bytes a pid, +1 state), not a
    duration the harness can guess (GATE-RACE-1)."""
    rows = row if isinstance(row, (list, tuple)) else [row or '']
    parts = ['', '']
    for r in rows:        # `sh: background output not redirected` may precede
        p = r.split()
        if len(p) == 2 and p[0].startswith('[') and p[1].isdigit():
            parts = p
    if not parts[1]:
        return False
    st = client.call_tool('peek', {
        'addr': 0x0800 + int(parts[1]) * 16 + 1, 'count': 1,
        'bank': 'aux', 'aux_bank': 0})
    return (st.get('bytes') or st.get('data'))[0] in (1, 2, 3)


# The holder jobs must still be running when the harness asks umount to
# refuse: ~1M guest cycles of harness per line, +3M under
# MAUX_GATE_RACE=late. 30 s is ~30M.
HOLD = 30


def bit_pos(client):
    return client.call_tool('disk2_state', {}).get('bit_pos')


D2_FIELDS = ('motor_on', 'track', 'quarter_track', 'bit_pos')


def d2_state(client):
    st = client.call_tool('disk2_state', {})
    return {k: st.get(k) for k in D2_FIELDS}


def sh(client, cmd, label, failures):
    return D.run_cmd(client, cmd + '\r', label, failures)


def status(client, failures, label):
    out = D.run_cmd(client, 'echo $?\r', label + ' status', failures)
    return out[-1] if out else None


def online_calls(client, cmd, label, failures, tries=16,
                 budget=3_000_000):
    """Type `cmd` and count the ON_LINE calls (PMLI_ONLN_CL) it makes,
    then wait for the prompt.  until_pc tests its condition BEFORE
    advancing, hence the step_inst past each hit."""
    from split_kseg import _read_symbol
    out = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
    onl = _read_symbol(out, 'PMLI_ONLN_CL')
    client.call_tool('type', {'text': cmd + '\r'})
    n = 0
    for _ in range(tries):
        r = client.call_tool('until_pc', {'pc': onl, 'max_cycles': budget})
        if not r.get('hit'):
            break
        n += 1
        client.call_tool('step_inst', {})
    D.wait_for_screen(client, D.prompt_ready, f'{label}: prompt',
                      max_steps=30000)
    return n


def unwrap(rows, cols=40):
    """Re-join a line the 40-column console wrapped (a row of exactly
    `cols` characters continues on the next)."""
    out, cur = [], ''
    for r in rows:
        cur += r
        if len(r) < cols:
            out.append(cur)
            cur = ''
    if cur:
        out.append(cur)
    return out


def eq(label, got, want, failures):
    D.assert_eq(label, got, want, failures)


def run(play, failures):
    tmp = tempfile.mkdtemp(prefix='maux-mount-')
    try:
        flop, second = make_volumes(tmp)
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
        env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
        client = MCPClient([SUPERVISOR], env)
        try:
            client.initialize()
            client.call_tool('reset', {'backend': 'fast'})
            mount_all(client, boot, second, flop)
            run_rows(client, failures)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_rows(client, failures):
    f = failures
    # -- 1: never poll --------------------------------------------------
    eq('1: ls -1 /mnt', sh(client, 'ls -1 /mnt', '1 ls', f),
       ['MAUX', 'SECOND'], f)
    eq('1: mount listing bytes', sh(client, 'mount', '1 mount', f),
       ['/dev/s7d1 on /mnt/MAUX', '/dev/s7d2 on /mnt/SECOND'], f)
    settle(client)
    b0 = bit_pos(client)
    eq('1: Disk II never spun (bit_pos)', b0, 0, f)

    # -- 2: mount names the drive, one ON_LINE ---------------------------
    eq('2: mount /dev/s6d1 is silent', sh(client, 'mount /dev/s6d1',
                                          '2 mount', f), [], f)
    eq('2: mount /dev/s6d1 exit', status(client, f, '2'), '0', f)
    settle(client)
    b1 = bit_pos(client)
    print(f'[check-mount] Disk II bit_pos after mount: {b1} '
          f'(one ON_LINE <= {ONE_ONLINE_MAX})')
    if not (isinstance(b1, int) and 0 < b1 <= ONE_ONLINE_MAX):
        f.append(f'2: bit_pos {b1!r} is not one ON_LINE '
                 f'(0 < n <= {ONE_ONLINE_MAX})')
    else:
        print('[check-mount] PASS 2: exactly one ON_LINE spun the drive')

    # -- 3: listed by name, readable -------------------------------------
    eq('3: ls -1 /mnt', sorted(sh(client, 'ls -1 /mnt', '3 ls', f)),
       ['FLOPPY.DISK.ABC', 'MAUX', 'SECOND'], f)
    eq('3: mount listing (boot first, then slot/drive)',
       sh(client, 'mount', '3 mount', f),
       ['/dev/s7d1 on /mnt/MAUX', '/dev/s6d1 on /mnt/FLOPPY.DISK.ABC',
        '/dev/s7d2 on /mnt/SECOND'], f)
    eq('3: ls /mnt/FLOPPY.DISK.ABC', sh(client, 'ls /mnt/FLOPPY.DISK.ABC', '3 ls fl', f),
       ['HELLO'], f)
    eq('3: cat /mnt/FLOPPY.DISK.ABC/HELLO',
       sh(client, 'cat /mnt/FLOPPY.DISK.ABC/HELLO', '3 cat', f), ['HI'], f)

    # -- 4: busy ----------------------------------------------------------
    sh(client, 'cd /mnt/FLOPPY.DISK.ABC', '4 cd', f)
    out = unwrap(sh(client, 'umount /mnt/FLOPPY.DISK.ABC', '4 umount', f))
    eq('4: umount with a cwd on it: diagnostic', out,
       ['umount: /mnt/FLOPPY.DISK.ABC: busy'], f)
    eq('4: umount with a cwd on it: exit', status(client, f, '4'), '1', f)
    sh(client, 'umount /dev/s6d1', '4 umount dev', f)
    eq('4: umount /dev/s6d1 with a cwd on it: exit',
       status(client, f, '4b'), '1', f)
    eq('4: still listed', sorted(sh(client, 'ls -1 /mnt', '4 ls', f)),
       ['FLOPPY.DISK.ABC', 'MAUX', 'SECOND'], f)

    # -- 4b/4c: busy for the OTHER two reasons (docs/KGAPS.md) -------------
    # VR_BUSY scans the open-file table before the cwds: an OFT_FILE
    # entry whose saved path is on the volume, then an OFT_BLK entry on
    # the unit. Row 4's busy came from the cwd, which is the LAST scan,
    # so neither OFT arm had ever run. The cwd is off the volume here
    # (`cd /`), and a background `sleep` holds the object open as its
    # stdin -- the shell opens a redirect for the child, the child
    # keeps the fd until it exits.
    sh(client, 'cd /', '4b cd', f)
    held = sh(client, f'sleep {HOLD} < /mnt/FLOPPY.DISK.ABC/HELLO &',
              '4b hold file', f)
    eq('4b: a background job holds a file on FLOPPY.DISK.ABC open',
       any(r.startswith('[1] ') for r in held), True, f)
    eq('4b: ...and it is still running (the overlap held)',
       job_alive(client, held), True, f)
    out = unwrap(sh(client, 'umount /mnt/FLOPPY.DISK.ABC', '4b umount', f))
    eq('4b: umount with a file open on it: diagnostic', out,
       ['umount: /mnt/FLOPPY.DISK.ABC: busy'], f)
    eq('4b: umount with a file open on it: exit',
       status(client, f, '4b'), '1', f)
    sh(client, 'wait', '4b wait', f)
    held = sh(client, f'sleep {HOLD} < /dev/s6d1 &', '4c hold unit', f)
    eq('4c: a background job holds the block device open',
       any(r.startswith('[1] ') for r in held), True, f)
    eq('4c: ...and it is still running (the overlap held)',
       job_alive(client, held), True, f)
    out = unwrap(sh(client, 'umount /dev/s6d1', '4c umount', f))
    eq('4c: umount with the unit open: diagnostic', out,
       ['umount: /dev/s6d1: busy'], f)
    eq('4c: umount with the unit open: exit',
       status(client, f, '4c'), '1', f)
    sh(client, 'wait', '4c wait', f)

    # -- 5: umount clears the bit ----------------------------------------
    sh(client, 'cd /', '5 cd', f)
    settle(client)
    b2 = bit_pos(client)
    eq('5: umount /mnt/FLOPPY.DISK.ABC is silent',
       sh(client, 'umount /mnt/FLOPPY.DISK.ABC', '5 umount', f), [], f)
    eq('5: umount exit', status(client, f, '5'), '0', f)
    settle(client)
    b3 = bit_pos(client)
    # umount maps the NAME to its unit with one ON_LINE on each
    # mounted unit (the sanctioned poll: the user named the volume),
    # so it spins the drive once -- at most one warm ON_LINE's worth.
    print(f'[check-mount] Disk II bits spun by umount: {b3 - b2}')
    if not (isinstance(b3, int) and 0 <= b3 - b2 <= ONE_WARM_MAX):
        f.append(f'5: umount spun {b3 - b2} bits; one ON_LINE is at '
                 f'most {ONE_WARM_MAX}')
    eq('5: /mnt without it', sh(client, 'ls -1 /mnt', '5 ls', f),
       ['MAUX', 'SECOND'], f)
    eq('5: mount listing without it', sh(client, 'mount', '5 mount', f),
       ['/dev/s7d1 on /mnt/MAUX', '/dev/s7d2 on /mnt/SECOND'], f)
    settle(client)
    eq('5: the listings after it read nothing', bit_pos(client), b3, f)

    # -- 6: refusals ------------------------------------------------------
    for cmd, msg in (
            ('umount /mnt/MAUX',
             'umount: /mnt/MAUX: not a mountable unit'),
            ('umount /mnt/SECOND',
             'umount: /mnt/SECOND: not a mountable unit'),
            ('mount /dev/s5d1', 'mount: /dev/s5d1: no device connected'),
            ('mount /dev/nope', 'mount: /dev/nope: not a mountable unit')):
        out = unwrap(sh(client, cmd, '6 ' + cmd, f))
        eq(f'6: {cmd}: diagnostic', out, [msg], f)
        eq(f'6: {cmd}: exit', status(client, f, '6'), '1', f)
    sh(client, 'mount /dev/s7d1', '6 mount fast', f)
    eq('6: mount /dev/s7d1 (a fast unit) is a no-op: exit',
       status(client, f, '6'), '0', f)
    eq('6: nothing changed', sh(client, 'ls -1 /mnt', '6 ls', f),
       ['MAUX', 'SECOND'], f)

    # -- 7: `..` ----------------------------------------------------------
    sh(client, 'cd /mnt/SECOND/SUB', '7 cd', f)
    eq('7: pwd', sh(client, 'pwd', '7 pwd', f), ['/mnt/SECOND/SUB/'], f)
    for want in ('/mnt/SECOND/', '/mnt/', '/', '/'):
        sh(client, 'cd ..', '7 cd ..', f)
        eq(f'7: cd .. -> {want}', sh(client, 'pwd', '7 pwd', f),
           [want], f)
    for start, here, want in (('/bin', '/bin/', '/'),
                              ('/mnt', '/mnt/', '/'),
                              ('/dev', '/dev/', '/'),
                              ('/mnt/MAUX', '/mnt/MAUX/', '/mnt/'),
                              ('/mnt/MAUX/BIN', '/bin/', '/')):
        sh(client, f'cd {start}', f'7 cd {start}', f)
        eq(f'7: cd {start}', sh(client, 'pwd', '7 pwd', f), [here], f)
        sh(client, 'cd ..', '7 cd ..', f)
        eq(f'7: cd {start}; cd ..', sh(client, 'pwd', '7 pwd', f),
           [want], f)
    sh(client, 'cd /mnt/SECOND/SUB', '7 cd', f)
    eq('7: find ..', sorted(sh(client, 'find ..', '7 find', f)),
       ['..', '../F', '../SUB'], f)    # -- 8: "/" is a table, not a directory you can write to ------------
    sh(client, 'cd /', '8 cd', f)
    for cmd in ('touch /X', 'mkdir /D', 'rmdir /mnt', 'rm /bin'):
        sh(client, cmd, '8 ' + cmd, f)
        eq(f'8: {cmd}: exit', status(client, f, '8'), '1', f)
    eq('8: / is unchanged', sh(client, 'ls -1 /', '8 ls', f),
       ['bin', 'dev', 'etc', 'mnt', 'tmp', 'usr'], f)

    # -- 9: /mnt/NAME names a volume the machine has (KFIX5) --------------
    sh(client, 'cd /', '9 cd', f)
    settle(client)
    base = d2_state(client)

    def still(label):
        """The drive has not moved in ANY field since the last call."""
        nonlocal base
        settle(client)
        now = d2_state(client)
        if now != base:
            f.append(f'{label}: the Disk II moved {base} -> {now}; the '
                     f'name reached the MLI')
        else:
            print(f'[check-mount] PASS {label}: {D2_FIELDS} unchanged '
                  f'(bit_pos {now["bit_pos"]})')
        base = now

    for cmd in ('ls /mnt/GONE', 'cat /mnt/GONE/x',
                'echo q > /mnt/GONE/x', 'cd /mnt/GONE',
                'test -d /mnt/GONE', 'ls /mnt/FLOPPY.DISK.ABC',
                'ls /mnt/ABCDEFGHIJKLMNOP'):
        sh(client, cmd, '9 ' + cmd, f)
        eq(f'9: {cmd}: exit', status(client, f, '9'), '1', f)
        still(f'9: {cmd}')
    eq('9: cd /mnt/GONE left the cwd alone',
       sh(client, 'pwd', '9 pwd', f), ['/'], f)
    sh(client, 'test -d /mnt/MAUX', '9 boot', f)
    eq('9: the boot volume: exit', status(client, f, '9'), '0', f)
    sh(client, 'test -d /mnt/maux', '9 boot lc', f)
    eq('9: ...in lower case: exit', status(client, f, '9'), '0', f)
    eq('9: a fast unit\'s volume, by name',
       sorted(' '.join(sh(client, 'ls /mnt/SECOND', '9 ls SECOND',
                          f)).split()), ['F', 'SUB'], f)
    eq('9: ...and by lower-case name',
       sorted(' '.join(sh(client, 'ls /mnt/second', '9 ls second',
                          f)).split()), ['F', 'SUB'], f)
    still('9: the reachable names')
    # the boot volume is a compare, no ON_LINE; any other name costs one
    # per fast unit until it is found, ONCE: the walk's last answer is
    # cached (VR_MNTCK's MC_KEEP) and a path under a non-boot cwd names
    # it on every call. `mount` and `umount` (even a fast unit's no-op
    # `mount`) drop it.
    for pre, cmd, want in ((None, 'test -d /mnt/MAUX', 0),
                           ('mount /dev/s7d1', 'test -d /mnt/SECOND', 1),
                           (None, 'test -d /mnt/SECOND', 0),
                           (None, 'test -d /mnt/second', 0),
                           ('mount /dev/s7d1', 'test -d /mnt/SECOND', 1)):
        if pre:
            sh(client, pre, '9 ' + pre, f)
        n = online_calls(client, cmd, f'9 {cmd}', f)
        if (n == 0) != (want == 0):
            f.append(f'9: {pre or ""} {cmd}: {n} ON_LINE call(s), want '
                     f'{"none" if want == 0 else "some"}')
        else:
            print(f'[check-mount] PASS 9: {pre or ""} {cmd}: {n} ON_LINE '
                  f'call(s)')
    # mounted, the floppy is a volume the machine has: ONE sanctioned
    # ON_LINE to read its name, then the rows read it
    sh(client, 'mount /dev/s6d1', '9 mount', f)
    eq('9: mounted, /mnt/FLOPPY.DISK.ABC is reachable',
       sh(client, 'ls /mnt/FLOPPY.DISK.ABC', '9 ls fl', f), ['HELLO'], f)
    sh(client, 'umount /dev/s6d1', '9 umount', f)
    eq('9: umount exit', status(client, f, '9'), '0', f)
    settle(client)
    base = d2_state(client)
    sh(client, 'ls /mnt/FLOPPY.DISK.ABC', '9 ls fl again', f)
    eq('9: unmounted again, /mnt/FLOPPY.DISK.ABC is refused: exit',
       status(client, f, '9'), '1', f)
    still('9: ls /mnt/FLOPPY.DISK.ABC after umount')



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-mount: {play} missing -- make play-image')
        return 2
    failures = []
    try:
        run(play, failures)
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-mount] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print('[check-mount] PASS: /mnt lists only mounted volumes, `mount` '
          'names a Disk ][ with exactly one ON_LINE and the listings never '
          'poll, busy and boot-volume refusals hold, and `..` walks '
          'the virtual root through cd and find')
    return 0


if __name__ == '__main__':
    sys.exit(main())
