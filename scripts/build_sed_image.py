#!/usr/bin/env python3
"""Build the ProDOS-hosted `sed` acceptance-gate image (`make
check-sed`). Companion to src/test/sedtest.s / sedtestb.s /
scripts/check_sed.py -- same transport shape as
scripts/build_find_image.py (a real userland binary spawned from disk
with fds redirected to ProDOS files, byte-exact comparison).

House rule (HACKING.md): disk images via a2til only.

THE ORACLE IS THE HOST'S OWN sed (docs/E2E.md sec 4, stage 1). This is
the tree's first per-program gate built DIFFERENTIAL from birth: for
runs 1-7, compute_expected() runs the IDENTICAL script through
/usr/bin/sed on the IDENTICAL input lines and translates the result
into maux's text convention (high-bit ASCII, CR line ends). No
expected byte string for those runs is authored by hand, and none may
EVER be captured from a maux run (E2E.md's rule: a suite whose
expectations came from the subject is a change detector that ratifies
bugs). The scripts were chosen to be POSIX-portable -- identical
under BSD and GNU sed -- so the host flavor does not matter; the gate
asserts host sed exits 0 on each of them, so a non-portable script
fails loudly here rather than encoding one host's quirk.

Runs 8-9 are maux's OWN error paths (open failure; the loud
bad-script refusal of a command that does not exist) -- there is no
host reference for their bytes, so they are invariants (E2E.md oracle
3), each carried as a NAMED divergence entry in check_sed.py. Runs
10-11 are the two declared boundaries (a final line without its CR;
the pattern-space cap). The broad POSIX-conformance corpus is
scripts/check_posixsed.py (`make check-posixsed`), which drives the
real binary through maux's own shell with -f scripts; this gate stays
the arena-poison + spawn-harness proof.
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXSEDTEST.SYSTEM')
SED_BIN = os.path.join(ROOT, 'build', 'sed.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'sed.po')
HOST_SED = os.environ.get('HOST_SED', '/usr/bin/sed')

CR = bytes([0x8D])

# The input corpus. Chosen so every staged script has something to
# bite on: 'l' runs for s/l*/X/g and s/l/L/2, 'ell' for the RE
# address, 'gamma' for the '&' case, and a second file so '$' means
# "last line of the LAST file".
LINES1 = ['alpha one', 'hello bell', 'gamma low', 'delta end']
LINES2 = ['omega last']
# SEDIN3's final line has NO terminator (docs/E2E.md sec 5's
# missing-trailing-newline boundary): run 10 asserts the declared
# divergence that maux's PRINTLINE appends a CR where the host
# preserves the absence.
LINES3_RAW = b'one\ntwo'          # host bytes; note no final \n

# run number -> (script, -n?, input files). Mirrors sedtestb.s's
# SETUP_ARGV exactly -- the harness stages these argv words verbatim.
# The script reaches the HOST as a BARE OPERAND, exactly the form
# maux is handed (adversarial review N5: an earlier draft passed the
# host '-e script' while maux got the bare word -- differential
# across a form maux cannot even accept, since -e/-f are refused as
# usage errors; that refusal is a named DIVERGENCE row now).
GROW10 = 's/./&&&&&&&&&&/g'          # x10 per pass; three passes
HOST_RUNS = {
    1: ('s/alpha/beta/', False, (1,)),
    2: ('/ell/p', True, (1,)),
    3: ('s/l*/X/g', False, (1,)),
    4: ('2,3d', False, (1,)),
    5: ('s/gamma/[&]/;s/l/L/2', False, (1,)),
    6: ('$p', True, (1, 2)),
    7: ('q', False, (1,)),
    10: ('s/x/y/', False, (3,)),
    11: (';'.join([GROW10] * 3), False, (1,)),
}


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


def to_maux(host_bytes):
    """Host sed output (7-bit, LF) -> maux text (high-bit, CR)."""
    out = bytearray()
    for b in host_bytes:
        out.append(0x8D if b == 0x0A else (b | 0x80))
    return bytes(out)


def maux_file(lines):
    return b''.join(hitext(l) + CR for l in lines)


def build():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSEDTEST.SYSTEM'),
        (SED_BIN, 'sed userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    shutil.copyfile(CARRIER_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'
    removed, kept = [], []

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            kept.append(entry.name)
            continue
        rm_recursive(f'{root}/{entry.name}', entry)
        removed.append(entry.name)

    with open(KERNEL_BIN, 'rb') as f:
        kernel = f.read()
    with open(SYS_BIN, 'rb') as f:
        system = f.read()
    with open(SED_BIN, 'rb') as f:
        sedbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SED', sedbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/SEDIN', maux_file(LINES1), file_type=0x04,
                 overwrite=True)
    prodos.write(f'{root}/SEDIN2', maux_file(LINES2), file_type=0x04,
                 overwrite=True)
    prodos.write(f'{root}/SEDIN3', to_maux(LINES3_RAW), file_type=0x04,
                 overwrite=True)

    prodos.unmount(CARRIER_VOL)

    print(f'[build-sed] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-sed] kept={kept} removed={removed}')
    print(f'[build-sed] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


def host_expected(tmpdir):
    """Runs 1-7 through the host reference. Returns {n: bytes}."""
    f1 = os.path.join(tmpdir, 'sedin1.txt')
    f2 = os.path.join(tmpdir, 'sedin2.txt')
    f3 = os.path.join(tmpdir, 'sedin3.txt')
    with open(f1, 'w') as f:
        f.write(''.join(l + '\n' for l in LINES1))
    with open(f2, 'w') as f:
        f.write(''.join(l + '\n' for l in LINES2))
    with open(f3, 'wb') as f:
        f.write(LINES3_RAW)
    paths = {1: f1, 2: f2, 3: f3}
    out = {}
    for n, (script, nflag, files) in sorted(HOST_RUNS.items()):
        cmd = [HOST_SED]
        if nflag:
            cmd.append('-n')
        cmd.append(script)           # BARE operand -- the exact form
                                     # maux is handed (see HOST_RUNS)
        cmd += [paths[i] for i in files]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(
                f'host sed refused run {n} ({cmd!r}): rc={r.returncode} '
                f'stderr={r.stderr!r}. The staged scripts must be '
                f'POSIX-portable -- fix the CASE, do not hand-author '
                f'the expectation.')
        out[n] = to_maux(r.stdout)
    return out


def compute_expected(image_path=OUT_IMG):
    """Every expected byte string, keyed run1..run9 (+_err/_status).

    Runs 1-7: host-differential (see module docstring). Runs 8-9:
    maux-invariant error paths -- the named divergence entries live
    in check_sed.DIVERGENCE.
    """
    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        host = host_expected(tmpdir)

    exp = {}
    for n in range(1, 8):
        exp[f'run{n}'] = host[n]
        exp[f'run{n}_err'] = b''       # a clean run writes NO stderr
        exp[f'run{n}_status'] = 0
    # -- run 10: the missing-final-newline boundary. The host
    # preserves the absence; maux's PRINTLINE appends a CR -- a
    # DECLARED divergence, asserted here: expected = the translated
    # host output PLUS the CR the host did not emit.
    assert not host[10].endswith(CR), 'host grew a final newline?'
    exp['run10'] = host[10] + CR
    exp['run10_err'] = b''
    exp['run10_status'] = 0
    # -- run 11: the pattern space grown past PSMAX (2047) on the
    # FIRST line (9 chars x 1000). The host prints all four lines
    # (host rc 0 was asserted above -- the script is portable); maux
    # prints nothing and dies LOUDLY. Declared divergence 'pattern
    # space cap', asserted.
    assert len(host[11]) > 4 * 2048, 'run 11 no longer overflows PSMAX'
    exp['run11'] = b''
    exp['run11_err'] = hitext('sed: pattern space overflow') + CR
    exp['run11_status'] = 2
    # -- run 8: open failure. Reported, exit 2 (grep.s's convention;
    # divergence entry 'open-failure text and status').
    exp['run8'] = b''
    exp['run8_err'] = hitext(f'sed: cannot open /mnt/{CARRIER_VOL}/NOSUCH') + CR
    exp['run8_status'] = 2
    # -- run 9: `k` is no sed command anywhere; the refusal must be
    # LOUD and name the spot (divergence entry 'unknown command
    # refused'). The parse cursor is still on the `k`, char 0.
    exp['run9'] = b''
    exp['run9_err'] = hitext('sed: unknown command near char 0') + CR
    exp['run9_status'] = 2

    # The harness strides results 128B stdout / 64B stderr per run
    # (sedtestb.s) -- an expectation that cannot fit would compare
    # truncated bytes and could pass wrongly. Refuse loudly instead.
    for n in range(1, 12):
        assert len(exp[f'run{n}']) < 128, \
            f'run{n} stdout {len(exp[f"run{n}"])}B >= 128B stride'
        assert len(exp[f'run{n}_err']) < 64, \
            f'run{n} stderr {len(exp[f"run{n}_err"])}B >= 64B stride'
    return exp


def main():
    rc = build()
    if rc:
        return rc
    expected = compute_expected(OUT_IMG)
    for n in range(1, 12):
        print(f'[build-sed] run{n} expected: {expected[f"run{n}"]!r} '
              f'stderr={expected[f"run{n}_err"]!r} '
              f'status={expected[f"run{n}_status"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
