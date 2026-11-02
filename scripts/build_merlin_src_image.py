#!/usr/bin/env python3
"""build_merlin_src_image.py -- work disk for rebuilding Merlin from its own
public-domain source, unattended (`make merlin-src-image`). Task #7.

WHY: docs/SELFHOST.md's dual-assembly gate needs real Merlin assembling
sources non-interactively. Merlin's own build is already close -- `L <file>`
then `ASM` -- but it stops to ask questions, and those questions come from the
`KBD` pseudo-op, which prompts at ASSEMBLY time and substitutes the answer as
a constant. Since the source is public domain we can just supply the constant.

Per the disk's own STEPBYSTEP, the answers are:

    SAVOBJ = 1     "Give value for SAVOBJ :"   (all four primary sources)
    ASM16  = 1     "Assemble from M-16:"       (MACASS.S only)

CVERS in SAVE/MERLIN.S ("Assemble one drive version") is left alone -- that
file builds the BINDER, which STEPBYSTEP BRUNs pre-built rather than
rebuilding.

Files are written at the VOLUME ROOT, replacing the originals in place. That
is deliberate: files inside a directory a2til creates are rejected by ProDOS
(a2til#13), so no new subdirectory is introduced here.

Needs vendor/VALIDATE.PO and vendor/merlin/ -- run `make vendor-merlin` first.
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_IMG = os.path.join(ROOT, 'vendor', 'VALIDATE.PO')
OUT_IMG = os.path.join(ROOT, 'build', 'merlinsrc.po')
MERLIN_SRC = os.path.join(ROOT, 'vendor', 'merlin')

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

# The four sources STEPBYSTEP assembles, in its order.
PRIMARY = ['INTERPRETER.S', 'MACED.S', 'MACEXEC.S', 'MACASS.S']

# KBD directive -> the constant STEPBYSTEP would have typed.
ANSWERS = {'SAVOBJ': 1, 'ASM16': 1}


KBD_RE = re.compile(r'^([A-Z_][A-Z0-9_.]*)\s+KBD(?:\s+"[^"]*")?\s*$')


def strip_kbd_bytes(raw):
    """Replace `NAME KBD ["prompt"]` lines, PRESERVING every other byte.

    Deliberately byte-level. These sources are NOT uniformly high-bit ASCII:
    INTERPRETER.S and MACED.S mix plain low-ASCII $20 spaces (1316 and 980 of
    them) into otherwise high-bit text. An earlier version decoded with
    `& 0x7F` and re-encoded with `| 0x80`, which silently rewrote every one of
    those to $A0. It still assembled -- Merlin treats either as whitespace --
    but any such byte inside an ASC literal would change the emitted object,
    and this file exists to support a BYTE-COMPARE against the shipped
    binary. So: only the matched lines are rebuilt; everything else is copied
    through untouched.

    Lines are $8D-terminated.

    Returns (patched_bytes, [(name, answer), ...]).
    """
    applied = []
    out = []
    for line in raw.split(b'\x8d'):
        text = bytes(b & 0x7F for b in line).decode('ascii', 'replace')
        m = KBD_RE.match(text)
        if m and m.group(1) in ANSWERS:
            name = m.group(1)
            applied.append((name, ANSWERS[name]))
            out.append(bytes((ord(ch) | 0x80)
                             for ch in f'{name} EQU {ANSWERS[name]}'))
        else:
            out.append(line)                    # untouched original bytes
    return b'\x8d'.join(out), applied


def main():
    for path in (SRC_IMG, MERLIN_SRC):
        if not os.path.exists(path):
            print(f'error: {path} not found -- run `make vendor-merlin` first',
                  file=sys.stderr)
            return 2

    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    shutil.copyfile(SRC_IMG, OUT_IMG)
    vol = a2til.open_image(OUT_IMG)

    total = 0
    for name in PRIMARY:
        host = os.path.join(MERLIN_SRC, name)
        raw = open(host, 'rb').read()
        out, applied = strip_kbd_bytes(raw)
        if not applied:
            print(f'[merlin-src] WARNING: no KBD directive matched in {name}',
                  file=sys.stderr)
        untouched = sum(1 for a, b in zip(raw, out) if a == b)
        vol.write_file(f'/SOURCE/{name}', out, file_type=0x04, aux_type=0,
                       overwrite=True)
        shown = ', '.join(f'{n}={v}' for n, v in applied) or 'none'
        print(f'[merlin-src] {name:<16} {len(out):>6}B  '
              f'({len(raw) - len(out):+d} vs original)  KBD -> EQU: {shown}')
        total += len(applied)

    # The last interactive prompt is NOT a KBD: "Update source (Y/N)?" is
    # guarded by MACED's SEARCHR byte, which PARMS patches at load time.
    # VALIDATE.PO ships no PARMS at all, so MACED's built-in default ("/",
    # $AF, negative) leaves the question ON. The shipping v2.58 disk's PARMS
    # sets that field to 0 -- "Question skipped if 0" per PARMS.S -- so
    # borrowing it makes the build fully unattended. PARMS must live in the
    # MAIN DIRECTORY (PARMS.S says so explicitly).
    # PARMS comes from the EMBEDDED blob by default. src/merlin/patches.py
    # carries it precisely "so the build has no external-file dependency",
    # and its two load-bearing bytes are asserted at import. An optional
    # local v2.58 disk still wins if it is readable, because a byte from
    # outside the repo is the stronger evidence -- but it is now a bonus,
    # not a requirement.
    #
    # WHY THIS CHANGED (2026-08-23). The old code guarded on
    # os.path.exists() and then read the disk. Under macOS TCC the EXISTS
    # CHECK SUCCEEDS AND THE READ RAISES, so a revoked Downloads permission
    # did not fall through to the friendly warning -- it crashed the build
    # and took check-merlin, check-dual and check-dialect with it: the
    # byte-identity gates guarding self-hosting, dark for a reason nothing
    # in the tree had changed. S5's adversarial review flagged exactly this
    # as non-blocking; it was blocking within the day.
    sys.path.insert(0, os.path.join(ROOT, 'src', 'merlin'))
    import patches  # noqa: E402 -- embedded PARMS, see above
    parms = patches.PARMS_BYTES
    origin = 'embedded (src/merlin/patches.py)'
    parms_src = os.path.expanduser(
        '~/Downloads/mdj/Downloads/Merlin-8 v2.58 (ProDOS) Disk 1-2.dsk')
    try:
        if os.path.exists(parms_src):
            src_vol = a2til.open_image(parms_src)
            parms = src_vol.read_file('/MERLIN.8/PARMS')
            origin = 'borrowed from the v2.58 disk'
    except (OSError, PermissionError) as exc:
        print(f'[merlin-src] NOTE: v2.58 disk unreadable ({exc.__class__.__name__});'
              f' using the embedded PARMS', file=sys.stderr)
    searchr = parms[0x11] if len(parms) > 0x11 else None
    vol.write_file('/SOURCE/PARMS', parms, file_type=0x06,
                   aux_type=0x8000, overwrite=True)
    print(f'[merlin-src] PARMS            {len(parms):>6}B  {origin} '
          f'(suppresses "Update source")')

    vol.flush()
    if total != 5:
        print(f'[merlin-src] ERROR: expected 5 KBD substitutions across the '
              f'four sources, made {total}', file=sys.stderr)
        return 1
    print(f'[merlin-src] {OUT_IMG} ready -- {total} prompts replaced by '
          f'constants; the build should now run unattended')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
