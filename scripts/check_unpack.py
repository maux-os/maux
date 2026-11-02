#!/usr/bin/env python3
"""check_unpack.py -- the other direction (`make check-unpack`,
docs/UNPACK-E2E.md): REAL `.SHK`/`.SDK` archives fetched from the wild
(fixtures/PROVENANCE.md), unpacked onto a running maux.

One continuous emulator session, check_floppy.py's own idiom (type a
line, poll `screen_text`'s `'main'` buffer for a settled `$` prompt --
two consecutive identical polls below the typed command). Three legs:

  A. `.SHK` straight onto the hard drive -- `cd /mnt/MAUX/OUT`, `nulib2 -x`
     both real freeware archives, `nulib2 -v` each (the machine's own
     listing). Export unit 1; on the host, every one of the eight
     records is compared byte-for-byte against a2til's own read of the
     SAME archive, and its ProDOS type/aux (from a2til `prodos.stat()`
     after export) against the archive's own record header fields --
     the same oracle host `nulib2 -v` independently confirms (checked
     once, by hand, before this gate was written).
  B. `.SDK` of a ProDOS disk -> a disk -> the files back. `nulib2 -x`
     DEMOPROG.SDK, `dd ... of=/dev/s7d2 conv=notrunc` -- the spare unit
     IS that disk -- `ls /mnt/DEMO.PROGRAM` proves it on the machine (a
     remount is measured, not assumed: see MEASURED note below), `cp`
     the largest inner file back, export and byte-compare both the
     copied-back file and the whole 280-block unit against the `.SDK`'s
     own disk_record bytes.
  C. `.SDK` of a DOS 3.3 disk -> a disk -> it BOOTS. `nulib2 -x`
     XMASADV.SDK, `dd` it onto the same spare unit a second time (blocks
     are blocks), export and compare, then a fresh reset and a
     STANDALONE slot-6 mount of the exported image -- DOS 3.3 boots to
     "SKIP THE INTRODUCTION? (YES OR NO)" from a disk maux itself wrote.
  PIPEOUT (docs/NUFX-PIPE.md), right after leg C: the SAME disk record,
     this time `nulib2 -p /mnt/MAUX/ARC/XMASADV.SDK CHRISTMAS.ADV | dd
     of=/dev/s7d2 conv=notrunc` -- no intermediate file, `-p`'s output
     going straight down a pipe into `dd`'s stdin. Export, compare
     against the same oracle bytes leg C uses, then its OWN fresh-reset
     standalone slot-6 boot proof.

Teeth, each a CLI flag, seen red (or seen to hide a defect) then
reverted -- run one at a time:
  --teeth-corrupt  flips one byte inside XMASADV.SDK's LZW payload on a
                   throwaway copy of the staged boot image -- maux's own
                   `nulib2 -x` must show a thread-CRC warning and the
                   later boot proof must NOT reach the intro prompt.
  --teeth-order    mounts leg C's exported image with `order:"do"`
                   (wrong for a `.po`) -- no boot prompt.
  --teeth-type     leg A's type/aux comparison is deliberately fed a
                   WRONG expected value for one record and the
                   assertion that would normally catch it is skipped --
                   proving the real (unflagged) comparison is
                   load-bearing, not decorative, without touching the
                   tool it is testing.
  --teeth-pipeout-wrongrecord
                   feeds pipeout's `-p` a FILE record's name (from
                   VBLSET.SHK) instead of XMASADV.SDK's own disk
                   record -- `dd` copies a few hundred bytes instead of
                   143,360, and the pipeout boot proof must find no
                   DOS 3.3 on the result.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR       # noqa: E402
from a2til import nufx, prodos                              # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)
from pt_f40 import (PT_F40_ADDR, PT_F40B_ADDR,               # noqa: E402
                     PT_F40_MAG1, PT_F40_MAG2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VBLSET_PATH = os.path.join(ROOT, 'fixtures', 'asimov', 'VBLSET.SHK')
SLOTSCAN_PATH = os.path.join(ROOT, 'fixtures', 'asimov', 'SLOTSCAN.SHK')
DEMOPROG_PATH = os.path.join(ROOT, 'fixtures', 'gem', 'DEMOPROG.SDK')
XMASADV_PATH = os.path.join(ROOT, 'fixtures', 'gem', 'XMASADV.SDK')

ARC_DIR = '/mnt/MAUX/ARC'
OUT_DIR = '/mnt/MAUX/OUT'
UNPACK_AFTER = os.path.join(ROOT, 'build', 'unpack-after.po')
UNPACK2_AFTER_B = os.path.join(ROOT, 'build', 'unpack2-after-b.po')
UNPACK2_REMOUNT = os.path.join(ROOT, 'build', 'unpack2-remount.po')
UNPACK2_AFTER_C = os.path.join(ROOT, 'build', 'unpack2-after-c.po')
UNPACK2_AFTER_PIPE = os.path.join(ROOT, 'build', 'unpack2-after-pipe.po')

CHUNK = 200_000
BOOT_MAX_STEPS = 1200
#: LZW/1 expand of a small (<15 KB) freeware archive -- generous.
XSMALL_MAX_STEPS = 1200
#: LZW/1 expand of a 140K disk image -- NUFX-SDK-NOTES/docs/FLOPPY-E2E
#: measured 42.7M cycles for a same-shape 280-block fixture; budgeted
#: with real margin.
XDISK_MAX_STEPS = 2500
DD_MAX_STEPS = 800
CMD_MAX_STEPS = 800
BOOTC_MAX_STEPS = 4000


# ---------------------------------------------------------------------------
# check_floppy.py's own screen/settle idiom, copied not imported (a gate
# script is not a library -- house convention).
# ---------------------------------------------------------------------------

def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def screen_blob(rows):
    return '\n'.join(rows)


def prompt_ready(rows):
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].rstrip() == '$'


def wait_for_screen(client, predicate, label, max_steps=1200, cycles=CHUNK):
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': cycles})
        rows = screen_rows(client)
        if predicate(rows):
            return rows
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def wait_for_needles(client, needles, label, max_steps, cycles=CHUNK):
    seen = set()
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': cycles})
        rows = screen_rows(client)
        blob = screen_blob(rows)
        for n in needles:
            if n in blob:
                seen.add(n)
        if seen.issuperset(needles):
            return rows
    missing = sorted(set(needles) - seen)
    raise RuntimeError(
        f'timed out waiting for {label}; never saw {missing}; screen was:\n'
        f'{screen_blob(rows)}')


def _below_cmd(rows, needle):
    i = -1
    for n, row in enumerate(rows):
        if needle in row:
            i = n
    if i < 0:
        return None
    out = [x.rstrip() for x in rows[i + 1:]]
    return [x for x in out if x.strip() and x.strip() != '$'
            and not x.strip().endswith('$')]


def run_cmd(client, cmd, max_steps=1200, measure_cycles=False,
            allow_timeout=False):
    """Type `cmd`, settle (two consecutive identical polls below the
    typed line), return (output_lines, cycles_or_None). If
    `allow_timeout`, a timeout returns (None, None) instead of raising --
    for a leg that may legitimately not settle (e.g. a corrupted-input
    tooth run)."""
    start = None
    if measure_cycles:
        start = client.call_tool('regs', {}).get('cycle', 0)
    client.call_tool('type', {'text': cmd + '\r'})
    prev = object()
    got = None
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': CHUNK})
        rows = screen_rows(client)
        if not prompt_ready(rows):
            continue
        now = _below_cmd(rows, cmd[:36])
        if now is not None and now == prev:
            got = now
            break
        prev = now
    if got is None:
        if allow_timeout:
            return None, None
        raise RuntimeError(f'timed out waiting for {cmd!r} to settle')
    cycles = None
    if measure_cycles:
        end = client.call_tool('regs', {}).get('cycle', 0)
        cycles = end - start
    return got, cycles


def compare_bytes(got, want, label, fails):
    if got == want:
        print(f'[check-unpack] {label}: byte-identical ({len(want)} bytes)')
        return True
    n = min(len(got), len(want))
    where = next((i for i in range(n) if got[i] != want[i]), n)
    fails.append(f'{label}: {len(got)} bytes, expected {len(want)}; '
                 f'first difference at byte offset {where}')
    return False


# ---------------------------------------------------------------------------
# Host-side oracle, built before the machine ever boots.
# ---------------------------------------------------------------------------

def _mask7(text):
    """A NuFX pathname decoded (a2til's NAME_ENCODING, mac_roman) back to
    its raw bytes, high bit stripped -- old P8 ShrinkIt archives (this
    project's DEMOPROG.SDK fixture among them) store the in-header name
    with every byte's bit 7 SET, the ordinary Apple II high-bit-ASCII
    display convention (HACKING.md's own "Classic Apple II source files
    are HIGH-BIT ASCII" note, learning:01M04J31Y8DQM8V8DSN4DK9HJH) --
    real ShrinkIt-family readers strip it; a ProDOS-legal name cannot
    otherwise be built from it (MLI CREATE would reject a high-bit
    character as a bad pathname)."""
    raw = text.encode('mac_roman')
    return bytes(b & 0x7F for b in raw).decode('ascii')


def load_shk_oracle(path):
    """(name, type, aux, data) for every record of a real .SHK, straight
    from a2til -- the second independent NuFX reader."""
    recs = []
    with nufx.NufxArchive(path) as arc:
        for r in arc.records:
            data = arc.read_file(r.pathname)
            recs.append({'name': _mask7(r.pathname), 'type': r.file_type & 0xFF,
                         'aux': r.extra_type & 0xFFFF, 'data': data})
    return recs


def load_sdk_oracle(path):
    """(name, image_bytes) for the one disk record of a real .SDK."""
    with nufx.NufxArchive(path) as arc:
        rec = arc.disk_record
        if rec is None:
            raise RuntimeError(f'{path}: a2til does not see a single disk '
                              f'record')
        return _mask7(rec.pathname), rec.read()


def load_demoprog_catalog(img_bytes):
    """The inner ProDOS volume's file set, the largest file's name and
    bytes -- what leg B's `ls`/`cp` steps are checked against."""
    fd, tmp = tempfile.mkstemp(suffix='.po', prefix='maux-unpack-inner-')
    os.close(fd)
    try:
        with open(tmp, 'wb') as f:
            f.write(img_bytes)
        prodos.mount(tmp, replace=True, readonly=True)
        try:
            vol = prodos.mounts()[0]
            entries = list(prodos.scandir('/' + vol))
            names = {e.name for e in entries}
            largest = max(entries, key=lambda e: e.size)
            largest_bytes = prodos.read('/' + vol + '/' + largest.name)
        finally:
            prodos.unmount(prodos.mounts()[0])
    finally:
        os.unlink(tmp)
    return names, largest.name, largest_bytes


def corrupt_sdk_archive(archive_path):
    """Flip one byte inside XMASADV.SDK's disk thread's COMPRESSED
    payload, IN THE ARCHIVE (--teeth-corrupt): a mid-stream bit flip
    that LZW/1 does not self-correct, so the v3 thread CRC (seed $FFFF
    over the plaintext, learning:01M0KZQJTHDP01FKPNP1HTWDW7) must
    disagree. Returns a temp copy of the ARCHIVE bytes (not the decoded
    disk image) with the flip applied; the ORIGINAL archive/image bytes
    are what every other comparison in this run still expects."""
    with open(archive_path, 'rb') as f:
        archive_bytes = bytearray(f.read())
    with nufx.NufxArchive(archive_path) as arc:
        rec = arc.disk_record
        thread = rec.disk_thread
        off = thread.payload_offset + len(thread.payload) // 2
    archive_bytes[off] ^= 0xFF
    fd, tmp = tempfile.mkstemp(suffix='.SDK', prefix='maux-unpack-bad-')
    os.close(fd)
    with open(tmp, 'wb') as f:
        f.write(archive_bytes)
    return tmp, off


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('unpackimage')
    ap.add_argument('unpack2image')
    ap.add_argument('--teeth-corrupt', action='store_true',
                    help='flip a byte in XMASADV.SDK\'s LZW payload -- '
                         'nulib2 -x must warn and the boot proof must fail')
    ap.add_argument('--teeth-order', action='store_true',
                    help='mount leg C\'s exported image with order:"do" -- '
                         'no boot prompt')
    ap.add_argument('--teeth-type', action='store_true',
                    help='feed leg A\'s type/aux compare a wrong expected '
                         'value and skip the assertion that would catch it')
    ap.add_argument('--teeth-pipeout-wrongrecord', action='store_true',
                    help='feed the pipeout leg -p a FILE record (from '
                         'VBLSET.SHK) instead of XMASADV.SDK\'s own disk '
                         'record -- dd copies the wrong length and the '
                         'boot must fail')
    args = ap.parse_args()

    unpackimage = os.path.abspath(args.unpackimage)
    unpack2image = os.path.abspath(args.unpack2image)

    print('[check-unpack] building the host-side oracle from the real '
          'archives...')
    vbl_recs = load_shk_oracle(VBLSET_PATH)
    slot_recs = load_shk_oracle(SLOTSCAN_PATH)
    all_recs = vbl_recs + slot_recs
    print(f'[check-unpack] oracle: {len(vbl_recs)} VBLSET.SHK record(s), '
          f'{len(slot_recs)} SLOTSCAN.SHK record(s)')
    for r in all_recs:
        print(f'    {r["name"]:<16s} type=${r["type"]:02X} '
              f'aux=${r["aux"]:04X} {len(r["data"])} byte(s)')

    demo_name, demo_img = load_sdk_oracle(DEMOPROG_PATH)
    xmas_name, xmas_img = load_sdk_oracle(XMASADV_PATH)
    print(f'[check-unpack] oracle: {demo_name} ({len(demo_img)} bytes, '
          f'ProDOS), {xmas_name} ({len(xmas_img)} bytes, DOS 3.3)')
    demo_names, demo_largest, demo_largest_bytes = \
        load_demoprog_catalog(demo_img)
    print(f'[check-unpack] oracle: {demo_name} inner catalog has '
          f'{len(demo_names)} file(s); largest is {demo_largest} '
          f'({len(demo_largest_bytes)} bytes)')

    boot_path = unpackimage
    corrupt_path = None
    corrupt_offset = None
    if args.teeth_corrupt:
        fd, boot_path = tempfile.mkstemp(suffix='.po',
                                         prefix='maux-unpack-corrupt-')
        os.close(fd)
        shutil.copyfile(unpackimage, boot_path)
        corrupt_path, corrupt_offset = corrupt_sdk_archive(XMASADV_PATH)
        with open(corrupt_path, 'rb') as f:
            bad_xmas = f.read()
        prodos.mount(boot_path, replace=True)
        try:
            prodos.write(f'{ARC_DIR}/XMASADV.SDK', bad_xmas, file_type=0xE0,
                         aux_type=0x8002, overwrite=True)
        finally:
            prodos.unmount('MAUX')
        print(f'[check-unpack] TEETH: flipped byte at archive offset '
              f'{corrupt_offset} inside XMASADV.SDK\'s LZW payload on a '
              f'throwaway copy of the boot image')

    fails = []
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                      'bank': 'main'})

        r1 = client.call_tool('mount_disk',
                              {'path': boot_path, 'unit': 1, 'copy': True})
        if r1.get('ok') is False:
            raise RuntimeError(f'mount_disk(unpack image) failed: {r1}')
        r2 = client.call_tool('mount_disk',
                              {'path': unpack2image, 'unit': 2, 'copy': True})
        if r2.get('ok') is False:
            raise RuntimeError(f'mount_disk(unpack2 image) failed: {r2}')
        print(f'[check-unpack] unit1={r1.get("ok")} unit2={r2.get("ok")}',
              file=sys.stderr)

        wait_for_screen(client, prompt_ready, 'shell prompt',
                        max_steps=BOOT_MAX_STEPS)
        print('[check-unpack] shell prompt reached')

        # ------------------------------------------------------------
        # LEG A: two real .SHK archives, straight onto the hard drive.
        # ------------------------------------------------------------
        run_cmd(client, f'cd {OUT_DIR}', max_steps=CMD_MAX_STEPS)

        cyc = {}
        for arcname in ('VBLSET.SHK', 'SLOTSCAN.SHK'):
            out, cycles = run_cmd(
                client, f'nulib2 -x {ARC_DIR}/{arcname}',
                max_steps=XSMALL_MAX_STEPS, measure_cycles=True)
            cyc[arcname] = cycles
            print(f'[check-unpack] nulib2 -x {arcname}: {cycles} cycles '
                  f'(~{cycles / 1_000_000.0:.2f}M)')
            if out:
                print(f'[check-unpack]   output: {out}')
            out, _ = run_cmd(client, f'nulib2 -v {ARC_DIR}/{arcname}',
                             max_steps=CMD_MAX_STEPS)
            print(f'[check-unpack] nulib2 -v {arcname} (machine): {out}')

        rexp = client.call_tool('image_export', {'unit': 1,
                                                  'path': UNPACK_AFTER})
        if rexp.get('ok') is False:
            raise RuntimeError(f'image_export(unit 1) failed: {rexp}')
        print(f'[check-unpack] image_export unit1: {rexp.get("bytes")} '
              f'bytes, sha256={rexp.get("sha256")}')

        prodos.mount(UNPACK_AFTER, replace=True, readonly=True)
        try:
            table = []
            for idx, r in enumerate(all_recs):
                path = f'/mnt/MAUX/OUT/{r["name"]}'
                try:
                    got = prodos.read(path)
                    st = prodos.stat(path)
                except Exception as exc:
                    fails.append(f'leg A: {path} was not written: {exc}')
                    continue
                identical = (got == r['data'])
                if not identical:
                    fails.append(f'leg A: {r["name"]} is {len(got)} bytes, '
                                 f'expected {len(r["data"])} byte-identical '
                                 f'to a2til\'s read of the archive')
                exp_type, exp_aux = r['type'], r['aux']
                if args.teeth_type and idx == 0:
                    # Break the EXPECTATION, not the tool: feed the
                    # comparison a deliberately wrong value and skip the
                    # assertion that would have caught it, proving the
                    # normal (unflagged) comparison is load-bearing.
                    bad_type = exp_type ^ 0x01
                    would_match = (st.type == bad_type and
                                  st.aux_type == exp_aux)
                    print(f'[check-unpack] TEETH: type/aux comparison '
                          f'SKIPPED for {r["name"]} -- fed expected '
                          f'type=${bad_type:02X} (real record is '
                          f'${exp_type:02X}); real stamp is '
                          f'type=${st.type:02X} aux=${st.aux_type:04X}, '
                          f'which would have FAILED against the '
                          f'deliberately wrong expectation and was '
                          f'never checked (would_match={would_match})')
                else:
                    if st.type != exp_type or st.aux_type != exp_aux:
                        fails.append(
                            f'leg A: {r["name"]} came back type '
                            f'${st.type:02X} aux ${st.aux_type:04X}, '
                            f'expected ${exp_type:02X}/${exp_aux:04X}')
                table.append((r['name'], st.type, st.aux_type, len(got),
                             identical))
            print('[check-unpack] leg A eight-file table:')
            print('    %-16s %6s %6s %8s %s'
                  % ('name', 'type', 'aux', 'bytes', 'identical'))
            for name, t, a, n, ok in table:
                print('    %-16s   $%02X  $%04X %8d %s'
                      % (name, t, a, n, ok))
        finally:
            prodos.unmount('MAUX')

        # ------------------------------------------------------------
        # LEG B: a real ProDOS .SDK -> a disk -> the files back.
        # ------------------------------------------------------------
        out, cyc['DEMOPROG.SDK'] = run_cmd(
            client, f'nulib2 -x {ARC_DIR}/DEMOPROG.SDK',
            max_steps=XDISK_MAX_STEPS, measure_cycles=True)
        print(f'[check-unpack] nulib2 -x DEMOPROG.SDK: '
              f'{cyc["DEMOPROG.SDK"]} cycles '
              f'(~{cyc["DEMOPROG.SDK"] / 1_000_000.0:.1f}M)')

        out, _ = run_cmd(client, f'ls -l {OUT_DIR}', max_steps=CMD_MAX_STEPS)
        want_size = str(len(demo_img))
        # A 40-column screen wraps a long name across two array rows
        # with NO separator (`DEMO.PROGR` / `AM`) -- join the raw rows
        # (not space-joined) before searching for the name, but keep a
        # space-joined blob for the size, which sits on the SAME row as
        # the name's first fragment and needs a boundary to not fuse
        # with neighbouring columns.
        tight = ''.join(out)
        loose = ' '.join(out)
        if demo_name not in tight:
            fails.append(f'leg B: `ls -l {OUT_DIR}` did not show '
                         f'{demo_name}: {out!r}')
        elif want_size not in loose:
            fails.append(f'leg B: `ls -l {OUT_DIR}` did not show '
                         f'{want_size} bytes for {demo_name}: {out!r}')
        else:
            print(f'[check-unpack] ls -l {OUT_DIR}: saw {demo_name} at '
                  f'{want_size} bytes (wrapped across the 40-col screen)')

        out, dd_cycles = run_cmd(
            client, f'dd if={OUT_DIR}/{demo_name} of=/dev/s7d2 conv=notrunc',
            max_steps=DD_MAX_STEPS, measure_cycles=True)
        want_records = f'{len(demo_img) // 512}+0 records out'
        if not any(want_records in ln for ln in out):
            fails.append(f'leg B: dd to /dev/s7d2 printed {out!r}, '
                         f'expected a {want_records!r} line')
        else:
            print(f'[check-unpack] dd {demo_name} -> /dev/s7d2: '
                  f'{dd_cycles} cycles, {out}')

        # -- prove it on the machine: `ls /DEMO.PROGRAM` sees the
        # -- rewritten volume. Measured, not assumed: if ProDOS still
        # -- answers from cached state (block 2 / the old volume name),
        # -- export unit 2 and remount it fresh for this ONE step,
        # -- rather than special-casing the kernel.
        out, _ = run_cmd(client, f'ls /mnt/{demo_name}', max_steps=CMD_MAX_STEPS,
                         allow_timeout=True)
        seen_names = set()
        if out:
            for ln in out:
                seen_names.update(tok for tok in ln.split() if tok)
        remount_needed = not demo_names.issubset(seen_names)
        if remount_needed:
            print(f'[check-unpack] MEASURED: `ls /mnt/{demo_name}` in place did '
                  f'not show the rewritten volume\'s catalog (saw {out!r}) '
                  f'-- ProDOS held stale state; remounting unit 2 fresh')
            rexp2 = client.call_tool('image_export',
                                     {'unit': 2, 'path': UNPACK2_REMOUNT})
            if rexp2.get('ok') is False:
                raise RuntimeError(f'image_export(unit 2, pre-remount) '
                                  f'failed: {rexp2}')
            client.call_tool('eject_disk', {'unit': 2})
            r2b = client.call_tool('mount_disk',
                                   {'path': UNPACK2_REMOUNT, 'unit': 2,
                                    'copy': True})
            if r2b.get('ok') is False:
                raise RuntimeError(f'remount(unit 2) failed: {r2b}')
            out, _ = run_cmd(client, f'ls /mnt/{demo_name}',
                             max_steps=CMD_MAX_STEPS)
            seen_names = set()
            for ln in out:
                seen_names.update(tok for tok in ln.split() if tok)
            if not demo_names.issubset(seen_names):
                fails.append(f'leg B: `ls /{demo_name}` after a fresh '
                             f'remount still does not show the catalog: '
                             f'{out!r} (wanted {sorted(demo_names)})')
            else:
                print(f'[check-unpack] MEASURED FACT: a remount (export + '
                      f'eject_disk + mount_disk) WAS required before '
                      f'ProDOS saw the block-level rewrite of unit 2')
        else:
            print(f'[check-unpack] MEASURED FACT: `ls /{demo_name}` saw '
                  f'the rewritten volume\'s catalog with NO remount -- '
                  f'ProDOS re-reads the volume directory on this open')

        out, _ = run_cmd(client,
                         f'cp /mnt/{demo_name}/{demo_largest} {OUT_DIR}/BACK.BIN',
                         max_steps=CMD_MAX_STEPS)

        rexp = client.call_tool('image_export', {'unit': 1,
                                                  'path': UNPACK_AFTER})
        if rexp.get('ok') is False:
            raise RuntimeError(f'image_export(unit 1, leg B) failed: {rexp}')
        prodos.mount(UNPACK_AFTER, replace=True, readonly=True)
        try:
            try:
                back = prodos.read(f'{OUT_DIR}/BACK.BIN')
            except Exception as exc:
                back = None
                fails.append(f'leg B: {OUT_DIR}/BACK.BIN was not written: '
                             f'{exc}')
        finally:
            prodos.unmount('MAUX')
        if back is not None:
            compare_bytes(back, demo_largest_bytes,
                         f'leg B: cp {demo_largest} -> BACK.BIN', fails)

        rexp2 = client.call_tool('image_export', {'unit': 2,
                                                   'path': UNPACK2_AFTER_B})
        if rexp2.get('ok') is False:
            raise RuntimeError(f'image_export(unit 2, leg B) failed: '
                              f'{rexp2}')
        with open(UNPACK2_AFTER_B, 'rb') as f:
            unit2_bytes = f.read()
        compare_bytes(unit2_bytes, demo_img, 'leg B: unit 2 vs DEMOPROG.SDK',
                     fails)

        # ------------------------------------------------------------
        # LEG C: a real DOS 3.3 .SDK -> a disk -> it BOOTS.
        # ------------------------------------------------------------
        out, cyc['XMASADV.SDK'] = run_cmd(
            client, f'nulib2 -x {ARC_DIR}/XMASADV.SDK',
            max_steps=XDISK_MAX_STEPS, measure_cycles=True,
            allow_timeout=args.teeth_corrupt)
        print(f'[check-unpack] nulib2 -x XMASADV.SDK: '
              f'{cyc["XMASADV.SDK"]} cycles; output={out}')
        if args.teeth_corrupt and out:
            # MEASURED (2026-09-29): this record predates v3 (RECVER<3),
            # so CRCVERIFY's thread-CRC check is skipped entirely --
            # nulib2ext.s's LZBAD path fires instead, from LZWFORK's own
            # stream CRC (LZ_CCRC vs LZ_SCRC), and the message is
            # "damaged compressed stream" (BADSTRM), not a CRC-mismatch
            # sentence. Either wording is evidence the corruption was
            # caught; only silence would be a problem.
            if not any('damaged' in ln.lower() or 'crc' in ln.lower()
                      for ln in out):
                fails.append(f'leg C TEETH: expected a corruption warning '
                             f'from nulib2 -x and saw none in {out!r}')

        dd_out, _ = run_cmd(
            client, f'dd if={OUT_DIR}/{xmas_name} of=/dev/s7d2 conv=notrunc',
            max_steps=DD_MAX_STEPS, allow_timeout=True)
        if dd_out is None:
            print('[check-unpack] leg C: dd to /dev/s7d2 did not settle '
                 '(no file, or a hung copy) -- ', end='')
            if args.teeth_corrupt:
                print('expected under --teeth-corrupt')
            else:
                fails.append('leg C: dd if=%s of=/dev/s7d2 timed out'
                             % f'{OUT_DIR}/{xmas_name}')
        else:
            want_records = f'{len(xmas_img) // 512}+0 records out'
            found = any(want_records in ln for ln in dd_out)
            if not found and not args.teeth_corrupt:
                fails.append(f'leg C: dd to /dev/s7d2 printed {dd_out!r}, '
                             f'expected a {want_records!r} line')
            print(f'[check-unpack] dd {xmas_name} -> /dev/s7d2: {dd_out}')

        rexp3 = client.call_tool('image_export', {'unit': 2,
                                                   'path': UNPACK2_AFTER_C})
        if rexp3.get('ok') is False:
            raise RuntimeError(f'image_export(unit 2, leg C) failed: '
                              f'{rexp3}')
        with open(UNPACK2_AFTER_C, 'rb') as f:
            unit2c_bytes = f.read()
        if not args.teeth_corrupt:
            compare_bytes(unit2c_bytes, xmas_img,
                         'leg C: unit 2 vs XMASADV.SDK', fails)
        else:
            same = (unit2c_bytes == xmas_img)
            print(f'[check-unpack] TEETH: unit 2 after the corrupted '
                  f'extract {"matches" if same else "does NOT match"} the '
                  f'true XMASADV.SDK bytes (expected NOT to match)')
            if same:
                fails.append('leg C TEETH: --teeth-corrupt left unit 2 '
                             'byte-identical to the true image -- the '
                             'corruption never reached the disk, so this '
                             'tooth demonstrates nothing')

        # ------------------------------------------------------------
        # PIPEOUT (docs/NUFX-PIPE.md): the same leg-C disk record, this
        # time straight from `-p` to `dd` with no intermediate file --
        # `nulib2 -p archive NAME | dd of=/dev/s7d2 conv=notrunc`. `-p`
        # already writes to FD_STDOUT generically (nulib2ext.s's
        # EXTRACT does not special-case a disk record), so this proves
        # the PIPE plumbing (sh's `|`, the kernel pipe, dd reading its
        # own stdin) end to end on a real 140K record, not just on
        # check-nulib2's own small self-authored fixtures.
        # --teeth-pipeout-wrongrecord swaps in a FILE record's name
        # from VBLSET.SHK instead: `-p` matches that record instead of
        # the (nameless, in this flag's world) disk one, `dd` copies a
        # few hundred bytes onto unit 2 instead of 143,360, and the
        # later boot proof must find no DOS 3.3 on it.
        # ------------------------------------------------------------
        if args.teeth_pipeout_wrongrecord:
            pipe_name = vbl_recs[0]['name']
            pipe_src = f'{ARC_DIR}/VBLSET.SHK'
        else:
            pipe_name = xmas_name
            pipe_src = f'{ARC_DIR}/XMASADV.SDK'
        pipe_dd_out, _ = run_cmd(
            client, f'nulib2 -p {pipe_src} {pipe_name} | '
                    f'dd of=/dev/s7d2 conv=notrunc',
            max_steps=XDISK_MAX_STEPS, allow_timeout=True)
        if pipe_dd_out is None:
            fails.append('pipeout: nulib2 -p | dd did not settle')
        else:
            # NOT "280+0" -- dd's INPUT here is the pipe end of `-p`'s
            # own output, not a block device, so its reads arrive in
            # whatever chunks the scheduler happened to interleave
            # nulib2's writes in; dd reports each one as its own
            # partial "record" (measured: '0+595 records in/out' for
            # this exact 143,360-byte record, every single one of
            # them short). check-floppy's own pipein case is the
            # mirror image and DOES get a clean '280+0': there, dd's
            # READS come off a real SmartPort device (/dev/s6d1),
            # which never returns short, and its WRITES (the pipe
            # side) already go through DD_WRTALL's own write-all
            # loop, absorbing any pipe short-write transparently. The
            # byte-for-byte export compare above is pipeout's real
            # correctness check; this assertion only proves dd
            # reached ITS OWN clean completion line rather than
            # hanging or erroring.
            found_pipe = any('records out' in ln for ln in pipe_dd_out)
            if args.teeth_pipeout_wrongrecord:
                print(f'[check-unpack] TEETH pipeout: {pipe_dd_out}')
            elif not found_pipe:
                fails.append(f'pipeout: dd printed {pipe_dd_out!r}, '
                             f'expected a "records out" completion line')
            else:
                print(f'[check-unpack] pipeout: nulib2 -p {pipe_src} '
                      f'{pipe_name} | dd of=/dev/s7d2: {pipe_dd_out}')

        rexp4 = client.call_tool('image_export', {'unit': 2,
                                                   'path': UNPACK2_AFTER_PIPE})
        if rexp4.get('ok') is False:
            raise RuntimeError(f'image_export(unit 2, pipeout) failed: '
                              f'{rexp4}')
        with open(UNPACK2_AFTER_PIPE, 'rb') as f:
            unit2p_bytes = f.read()
        if not args.teeth_pipeout_wrongrecord:
            compare_bytes(unit2p_bytes, xmas_img,
                         'pipeout: unit 2 vs XMASADV.SDK', fails)
        else:
            same_p = (unit2p_bytes == xmas_img)
            print(f'[check-unpack] TEETH pipeout: unit 2 after the wrong-'
                  f'record pipe {"matches" if same_p else "does NOT match"} '
                  f'the true XMASADV.SDK bytes (expected NOT to match)')
            if same_p:
                fails.append('pipeout TEETH: --teeth-pipeout-wrongrecord '
                             'left unit 2 byte-identical to the true '
                             'image -- the wrong record never reached '
                             'the disk, so this tooth demonstrates '
                             'nothing')

    finally:
        client.close()

    # -- the boot proof: a FRESH session (its own `reset`, no other unit
    # -- mounted) -- the exported image ALONE on slot 6. DOS 3.3 boots
    # -- from a disk maux itself wrote, or it does not -- this is the
    # -- mechanism check, not a byte compare. A separate client (rather
    # -- than reusing the long-lived one above, which has by now done
    # -- many mounts/ejects/exports) avoids whatever state a marathon
    # -- session accumulates; "a fresh reset" in the spec's own words.
    boot_client = MCPClient([SUPERVISOR], env)
    try:
        boot_client.initialize()
        boot_client.call_tool('reset', {'backend': 'fast'})
        mount_args = {'path': UNPACK2_AFTER_C, 'slot': 6, 'order': 'po'}
        if args.teeth_order:
            mount_args['order'] = 'do'
        rboot = boot_client.call_tool('mount_disk', mount_args)
        print(f'[check-unpack] leg C boot mount: {rboot}', file=sys.stderr)
        if rboot.get('ok') is False:
            if args.teeth_order or args.teeth_corrupt:
                print(f'[check-unpack] TEETH: boot mount refused outright: '
                      f'{rboot}')
            else:
                raise RuntimeError(f'leg C boot mount_disk failed: {rboot}')
        else:
            needle = 'SKIP THE INTRODUCTION'
            try:
                wait_for_needles(boot_client, [needle], 'DOS 3.3 intro '
                                 'prompt', max_steps=BOOTC_MAX_STEPS)
                print(f'[check-unpack] leg C boot: saw {needle!r}')
                if args.teeth_order or args.teeth_corrupt:
                    fails.append(f'leg C TEETH: expected NO boot prompt '
                                 f'under this tooth, but saw {needle!r}')
            except RuntimeError as exc:
                if args.teeth_order or args.teeth_corrupt:
                    print(f'[check-unpack] TEETH: no boot prompt, as '
                          f'expected ({exc})')
                else:
                    fails.append(f'leg C: {exc}')
    finally:
        boot_client.close()

    # -- the SAME boot proof, for the PIPEOUT export -- its own fresh
    # -- session (the leg-C hang this project measured once already:
    # -- a long-lived session's Nth `reset` + `mount_disk(slot:6)` left
    # -- `screen_text` answering an empty `main` buffer forever, where a
    # -- fresh session's first `reset` did not -- docs/UNPACK-E2E-
    # -- NOTES.md, [reported]). Skipped entirely under
    # -- --teeth-pipeout-wrongrecord's sibling flags (order/corrupt),
    # -- which never touch the pipe route at all.
    pipe_boot_client = MCPClient([SUPERVISOR], env)
    try:
        pipe_boot_client.initialize()
        pipe_boot_client.call_tool('reset', {'backend': 'fast'})
        rpboot = pipe_boot_client.call_tool(
            'mount_disk', {'path': UNPACK2_AFTER_PIPE, 'slot': 6,
                           'order': 'po'})
        print(f'[check-unpack] pipeout boot mount: {rpboot}',
              file=sys.stderr)
        if rpboot.get('ok') is False:
            if args.teeth_pipeout_wrongrecord:
                print(f'[check-unpack] TEETH pipeout: boot mount refused '
                      f'outright: {rpboot}')
            else:
                raise RuntimeError(f'pipeout boot mount_disk failed: '
                                   f'{rpboot}')
        else:
            needle = 'SKIP THE INTRODUCTION'
            try:
                wait_for_needles(pipe_boot_client, [needle],
                                 'DOS 3.3 intro prompt (pipeout)',
                                 max_steps=BOOTC_MAX_STEPS)
                print(f'[check-unpack] pipeout boot: saw {needle!r}')
                if args.teeth_pipeout_wrongrecord:
                    fails.append(f'pipeout TEETH: expected NO boot prompt '
                                 f'under --teeth-pipeout-wrongrecord, but '
                                 f'saw {needle!r}')
            except RuntimeError as exc:
                if args.teeth_pipeout_wrongrecord:
                    print(f'[check-unpack] TEETH pipeout: no boot prompt, '
                          f'as expected ({exc})')
                else:
                    fails.append(f'pipeout: {exc}')
    finally:
        pipe_boot_client.close()

    if fails:
        print('[check-unpack] FAIL:')
        for f in fails:
            print('  - ' + f)
        return 1
    if (args.teeth_corrupt or args.teeth_order or args.teeth_type
            or args.teeth_pipeout_wrongrecord):
        print('[check-unpack] TEETH PASS: the named tooth behaved as '
              'documented')
    else:
        print('[check-unpack] PASS: real .SHK archives unpack onto the '
              'hard drive byte- and type-exact; a real ProDOS .SDK images '
              'onto a spare unit and its files copy back; a real DOS 3.3 '
              '.SDK images onto a unit and BOOTS from it, both via '
              '`-x`+`dd` and straight through a `-p`|`dd` pipe')
    return 0


if __name__ == '__main__':
    sys.exit(main())
