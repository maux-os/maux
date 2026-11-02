#!/usr/bin/env python3
"""build_ld_image.py -- assemble the `ld` acceptance-gate image
(`make check-ld`). Companion to src/test/ldtest.s / ldtestb.s /
scripts/check_ld.py. Same shape as build_as_image.py (kernel + a
hardwired parent-process SYSTEM file + userland binaries + test data on
a maux-hosted ProDOS carrier), extended with a REFERENCE artifact
build_as_image.py never needed: `ld`'s own bar is "byte-identical to
the SAME link performed by the stock toolchain" (docs/LD-DESIGN.md
section 0), and unlike `as`'s merlin32-on-the-host reference, LINK has
no host-side equivalent (docs/AS-DESIGN.md section 10's own dialect
gaps -- merlin32 cannot even assemble this vendor tree without
workarounds, let alone run a REL-module LINK). So the reference is
produced the SAME way scripts/check_rel.py already proves the stock
answer: boot real Merlin-8 under verilogapple, assemble RTLIB.S/
RTMAIN.S, `LINK $2000,RTNAMES`, and peek the resulting bytes straight
out of memory -- reusing check_rel.py's own driving helpers (imported,
not duplicated) since it already solved the "how do you drive Merlin's
menu deterministically" problem.

Two artifacts:
  build/ld-rel.po      an INDEPENDENT copy of the rel-image setup
                        (own vendor+relspike mirror, never reuses
                        build/rel.po -- that file is check-rel's own
                        artifact, and a `ld`-owned script rebuilding it
                        from scratch avoids any get-stale-together risk
                        with a gate this task does not own).
  build/rtlinked.bin   the 72-byte STOCK reference link output, peeked
                        from $0900 after `LINK $2000,RTNAMES` on that
                        same disk (docs/LD-RECON.txt section 4's own
                        "conventionally $0901" / check_rel.py's own
                        IMAGE_AT=$0900 -- same module pair, same
                        constants, so the same address applies).
  build/ld.po           the maux-hosted disk `ld` itself runs from:
                        kernel + LDTEST.SYSTEM (hardwired parent
                        process) + sh.bin + ld.bin + the RTLIB/RTMAIN
                        REL objects (extracted from build/ld-rel.po,
                        the SAME bytes the reference was linked from)
                        + a staged sh script.

Needs vendor/VALIDATE.PO (`make vendor-merlin`).
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from check_rel import screen, wait, settle, assemble  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.dirname(os.path.abspath(__file__))

SRC_IMG = os.path.join(ROOT, 'vendor', 'VALIDATE.PO')
RELSPIKE_DIR = os.path.join(ROOT, 'src', 'relspike')
LDREL_IMG = os.path.join(ROOT, 'build', 'ld-rel.po')
REF_BIN = os.path.join(ROOT, 'build', 'rtlinked.bin')
IMAGE_DIR = '/SOURCE'
LINK_ADDR = 0x2000
IMAGE_AT = 0x0900
EXPECT_BYTES = 72
MENU_MARKER = 'L :Load source'

CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'LDTEST.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
# WHICH LINKER BINARY IS UNDER TEST. Defaults to `ld`, which IS the
# native two-pass linker now. LD_UNDER_TEST=mld stages the Merlin
# bridge instead -- it has no library search, so the -l/-L/-t links
# below are skipped for it.
#
# IT IS STILL STAGED AND INVOKED AS `LD`. The point is to judge the
# rewrite by the gate the bridge already passes -- same image, same
# script, same stock reference, and the harness's own direct-spawn and
# error-path steps (ldtestb.s) reach /bin/LD by name. Staging it
# under its own name instead makes those steps fail for a reason that
# has nothing to do with linking, which is how the first run of this
# was read (docs/LD-NATIVE.md step 2).
LD_NAME = os.environ.get('LD_UNDER_TEST', 'ld')
LD_BIN = os.path.join(ROOT, 'build', f'{LD_NAME}.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'ld.po')

# Run 1 (ldtestb.s's PARENT_PROC): `sh` (stdin from a staged script)
# runs the SAME link TWICE, adjacently, into two different output
# files, then `EXIT`. Both are checked host-side against
# build/rtlinked.bin.
#
# THE SECOND LINE IS THE WHOLE POINT (docs/STICKY.md sec 31). This
# gate used to link exactly ONCE per boot, and that is why it never
# saw the defect sec 29 found: lazy free retains a dead process's bank
# and serves the next spawn of the same program out of it WITHOUT
# recopying the text, so `ld`'s second invocation was the first one
# running on its own leftovers -- and it died there, with no output
# file, for as long as nothing in the tree ran `ld` twice. A gate that
# cannot observe a second invocation cannot see that class of bug at
# all. The two lines must stay ADJACENT: anything spawned between them
# can reclaim the bank and make run 2 cold, which passes vacuously.
# check_ld.py reads the kernel's own LZ_WARM to refuse that.
# `-a 2000`: ld's DEFAULT link address became LOAD_BASE ($800) when
# the REL route made the address a link-time parameter (S9 L3); this
# gate's stock reference was linked at $2000 and stays there, so the
# script says so explicitly -- which also exercises the -a parser.
_LD = 'LD'
# THE -l CASE, only for the native linker: the bridge has no library
# search and never will. RTMAIN references LIBUSED, which RTLIB
# defines, so `-lc` must find RTLIB in /usr/lib/LIBC and pull it in
# WITHOUT it being named -- and the result must be the same bytes the
# stock LINK produced when it WAS named.
# Three native-only links, each closing a gap the first -l test left:
#   LDOUT3  the default library path, with a decoy to reject
#   LDOUT4  a -L search path AND the fixpoint rescan -- QA satisfies
#           RTMAIN and itself references QB, so including QA creates a
#           NEW undefined symbol that only a SECOND sweep resolves. If
#           the rescan never runs this link fails outright.
#   SYSOUT  a ProDOS SYSTEM file: -t FF with -a 2000 is what ProDOS's
#           system loader wants, and the link address is already in aux
#   LDOUT5  -L resolving an EXPLICIT MODULE OPERAND (ONLYL, bare, no
#           slash) -- must succeed, and via the ATTACHED -L form
#           (-L/mnt/MAUX/MYMOD, one token) so that spelling is exercised
#           by a real boot too, not just the host-side character/
#           token-count measurement.
#   (no output) the SAME bare "ONLYL" operand, -L omitted -- must
#           FAIL. ONLYL exists nowhere a bare operand can otherwise
#           reach (not cwd-relative /mnt/MAUX/ONLYL, not under
#           /usr/lib), so this run has no way to succeed by
#           accident; it is the teeth for LDOUT5's claim that -L,
#           not something else, is what found it.
_LIBLINE = ((f'{_LD} -a 2000 -o /mnt/MAUX/LDOUT3 /mnt/MAUX/RTMAIN -l c\r'
             f'{_LD} -a 2000 -o /mnt/MAUX/LDOUT4 /mnt/MAUX/RTMAIN '
             f'-L /mnt/MAUX/MYLIB -l q\r'
             f'{_LD} -t FF -a 2000 -o /mnt/MAUX/SYSOUT /mnt/MAUX/RTMAIN '
             f'/mnt/MAUX/RTLIB\r'
             # -l on a library that exists nowhere: it must REFUSE,
             # not link RTMAIN alone and leave LIBUSED dangling.
             f'{_LD} -a 2000 -o /mnt/MAUX/NOLIB /mnt/MAUX/RTMAIN -l zzz\r'
             f'{_LD} -a 2000 -o /mnt/MAUX/LDOUT5 -L/mnt/MAUX/MYMOD ONLYL\r'
             f'{_LD} -a 2000 -o /mnt/MAUX/LDOUT6 ONLYL\r'
             # ARGUMENT FILES (KFIX3 item 0, src/bin/ldargf.s):
             #   LDOUT7  the same link as LDOUT, its words in a file
             #           (LDARGS, a low-ASCII TXT file as the staging
             #           writes it, the words on two lines)
             #   LDOUT8  `@FILE` followed by another word: refused
             #           (usage), so no output (LDARGS2 names LDOUT8
             #           and would link if the extra word were
             #           ignored)
             #   LDOUT9  an argument file of EXACTLY 1,022 bytes, the
             #           longest ld accepts (ARGFLIM is 1,023 and a
             #           read that fills it is refused), its last
             #           word ending on the buffer's last byte with
             #           no line end after it
             #   LDOUT10 the same file one blank longer (1,023 B): a
             #           full buffer, refused, so no output
             #   LDOUT11 a short file whose last word has no line end
             #           (review F6; the planner used to assert 1,023)
             f'{_LD} @/mnt/MAUX/LDARGS\r'
             f'{_LD} @/mnt/MAUX/LDARGS2 -z\r'
             f'{_LD} @/mnt/MAUX/LDARGS3\r'
             f'{_LD} @/mnt/MAUX/LDARGS4\r'
             f'{_LD} @/mnt/MAUX/LDARGS5\r')
            if LD_NAME != 'mld' else '')
SCRIPT_TEXT = (
    f'{_LD} -a 2000 -o /mnt/MAUX/LDOUT /mnt/MAUX/RTMAIN /mnt/MAUX/RTLIB\r'
    f'{_LD} -a 2000 -o /mnt/MAUX/LDOUT2 /mnt/MAUX/RTMAIN /mnt/MAUX/RTLIB\r'
    + _LIBLINE +
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)


def names_file(paths):
    out = bytearray()
    for p in paths:
        out.append(len(p))
        out += bytes((ord(c) | 0x80) for c in p)
        out.append(0x00)
    out.append(0x00)
    return bytes(out)


def build_ldrel_and_reference():
    """Own copy of the rel-image setup (never reuses build/rel.po),
    then boots it, assembles RTLIB.S/RTMAIN.S, links them, and peeks
    the reference bytes -- reusing check_rel.py's own menu-driving
    helpers verbatim (imported, not forked)."""
    if not os.path.exists(SRC_IMG):
        print(f'error: {SRC_IMG} not found -- run `make vendor-merlin` '
              f'first', file=sys.stderr)
        return 2
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    shutil.copyfile(SRC_IMG, LDREL_IMG)

    nf = names_file([f'{IMAGE_DIR}/RTMAIN', f'{IMAGE_DIR}/RTLIB'])
    with open(os.path.join(RELSPIKE_DIR, 'RTNAMES#068000'), 'wb') as fh:
        fh.write(nf)

    vol = a2til.open_image(LDREL_IMG)
    for host in sorted(os.listdir(RELSPIKE_DIR)):
        if host.startswith('.'):
            continue
        name, _, suffix = host.partition('#')
        ftype = int(suffix[:2], 16) if suffix else 0x06
        aux = int(suffix[2:], 16) if len(suffix) > 2 else 0
        with open(os.path.join(RELSPIKE_DIR, host), 'rb') as fh:
            data = fh.read()
        vol.write_file(f'{IMAGE_DIR}/{name}', data, file_type=ftype,
                       aux_type=aux, overwrite=True)
    vol.flush()

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        for unit in range(1, 7):
            c.call_tool('eject_disk', {'unit': unit})
        c.call_tool('reset', {'backend': 'fast'})
        r = c.call_tool('mount_disk', {'path': os.path.abspath(LDREL_IMG)})
        if r.get('unit') != 1 or r.get('unit_count') != 1:
            raise RuntimeError(f'expected a lone image on unit 1, got {r}')
        wait(c, MENU_MARKER)
        settle(c)
        print('[build-ld] Merlin-8 2.59 booted to its menu')

        for name, want in (('RTLIB', 68), ('RTMAIN', 4)):
            line = assemble(c, name)
            print(f'[build-ld] {name:<7} {line}')
            if f'{want} bytes' not in line or 'Errors: 0' not in line:
                raise RuntimeError(f'{name} did not assemble cleanly: '
                                   f'{line!r}')

        c.call_tool('type', {'text': 'E'})
        wait(c, 'Editor')
        settle(c)
        c.call_tool('type', {'text': 'NEW\r'})
        settle(c, 2)
        c.call_tool('type', {'text': f'LINK ${LINK_ADDR:04X},RTNAMES\r'})
        s = wait(c, 'Errors:')
        link_line = next(l.strip() for l in s.splitlines()
                          if 'Errors:' in l)
        print(f'[build-ld] stock link: {link_line}')
        if f'{EXPECT_BYTES} bytes' not in link_line or \
           'Errors: 0' not in link_line:
            raise RuntimeError(f'stock LINK did not produce the expected '
                               f'clean {EXPECT_BYTES}-byte link: '
                               f'{link_line!r}')

        # AUX $1000, NOT main $0900: LINKER.S's own final AUXMOVE moves
        # the built image from the main-memory staging buffer (where
        # check_rel.py's own IMAGE_AT=$0900 peek reads, main $0900-$0947
        # here) out to SYMADR (stock $1000, AUX memory -- the process-
        # patched core relocates this to main $2000, P1, but THIS boot
        # is the STOCK unpatched disk, so SYMADR really is aux $1000).
        # The two are NOT byte-identical: LINKED's own tail does `LDA
        # #$FF / STY ORGFLG / STA (ENDSRC),Y` AFTER the AUXMOVE, writing
        # a "valid" sentinel back into the MAIN staging buffer at
        # ENDSRC (=SOURCE, one past the page-rounded SPNT the image
        # itself starts at) -- corrupting the MAIN copy's own byte 1
        # with $FF but leaving the AUX copy (already moved out before
        # that write) untouched. `ld`'s own output comes from OBJPNT
        # (the real final destination, main $2000 under P1 -- the
        # process-model equivalent of aux $1000 here), so the reference
        # must be the AUX copy, not the main one, or the two would
        # differ by exactly that one marker byte. Found live comparing
        # `ld`'s own (correct) output against an aux-$0900-sourced
        # reference that had the $FF baked in.
        mem = c.call_tool('peek', {'addr': 0x1000, 'count': EXPECT_BYTES,
                                   'bank': 'aux', 'aux_bank': 0})['bytes']
        ref = bytes(mem)
        with open(REF_BIN, 'wb') as fh:
            fh.write(ref)
        print(f'[build-ld] wrote {REF_BIN} ({len(ref)}B, stock reference, '
              f'from aux $1000)')
    finally:
        c.close()

    # Extract the just-assembled RTLIB/RTMAIN objects for staging onto
    # the maux-hosted image -- the SAME bytes the reference above was
    # linked from (this reopens the image fresh from disk; verilogapple
    # flushes writes back to the mounted file, matching check_ascore.py's
    # own "the bind already replaced the boot file" precedent). aux_type
    # is NOT cosmetic here -- it is where real Merlin's own SAVE records
    # the module's CODE-portion length ("Length of code in LNK files",
    # vendor/merlin/MERLIN.GP.S's own INFAUX comment), which this file's
    # own LD_JRLOAD (src/bin/ld.s) reads back via GET_FILE_INFO to learn
    # how many of a module's bytes are code vs dictionary -- confirmed
    # empirically against build/rel.po's own already-assembled copies:
    # RTLIB type=$F8 aux_type=$44(68, its code length), RTMAIN type=$F8
    # aux_type=$04(4). Re-staging with aux_type=0 would silently break
    # LD_JRLOAD's own code/dictionary split, so the REAL values are read
    # back via scandir and threaded through to build/ld.po's own write,
    # not hardcoded.
    vol = a2til.open_image(LDREL_IMG)
    info = {e.name: (e.type, e.aux_type) for e in vol.scandir(IMAGE_DIR)}
    rtlib = bytes(vol.read_file(f'{IMAGE_DIR}/RTLIB'))
    rtmain = bytes(vol.read_file(f'{IMAGE_DIR}/RTMAIN'))
    rtlib_type, rtlib_aux = info['RTLIB']
    rtmain_type, rtmain_aux = info['RTMAIN']
    print(f'[build-ld] extracted RTLIB ({len(rtlib)}B, type='
          f'${rtlib_type:02X} aux=${rtlib_aux:04X}), RTMAIN '
          f'({len(rtmain)}B, type=${rtmain_type:02X} '
          f'aux=${rtmain_aux:04X}) from {LDREL_IMG}')
    return (rtlib, rtlib_type, rtlib_aux), (rtmain, rtmain_type, rtmain_aux)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'LDTEST.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (LD_BIN, 'ld userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    (rtlib, rtlib_type, rtlib_aux), (rtmain, rtmain_type, rtmain_aux) = \
        build_ldrel_and_reference()

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
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(LD_BIN, 'rb') as f:
        ldbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    if LD_NAME != 'mld':
        prodos.mkdir(f'{root}/USR')       # /usr/lib is the default -l dir
        prodos.mkdir(f'{root}/USR/LIB')
        prodos.mkdir(f'{root}/USR/LIB/LIBC')
        prodos.write(f'{root}/USR/LIB/LIBC/RTLIB', rtlib, file_type=0xF8,
                     aux_type=68, overwrite=True)
        # A DECOY MEMBER, and it is the point of the test: selectivity
        # is what separates a real `-l` from a glob, and only a member
        # that must be REJECTED can prove it.
        #
        # IT HAS TO DECLARE AN ENT. The first version of this decoy
        # was a copy of RTMAIN, which declares NONE -- and a decoy
        # with no ENT can never be pulled in whatever the linker
        # does, because the wanted-test only ever examines ENT
        # records. Sabotaging selectivity left the output identical,
        # which is how the vacuity showed up.
        #
        # So it is synthesised (docs/REL-FORMAT.md is the spec): four
        # bytes of code, no fixups, one ENT nobody references. A
        # linker that takes whatever it finds appends those four
        # bytes and LDOUT3 stops matching at 76 vs 72.
        decoy = (bytes([0xEA, 0xEA, 0xEA, 0x60])       # code: nops, rts
                 + bytes([0x00])                        # empty fixup list
                 + bytes([0x40 | 8]) + b'ZZUNUSED'      # ENT, 8 chars
                 + bytes([0x00, 0x80])                  # addr $8000
                 + bytes([0x00]))                       # end of symbols
        prodos.write(f'{root}/USR/LIB/LIBC/DECOY', decoy, file_type=0xF8,
                     aux_type=4, overwrite=True)
        # A CHAINED library under a NON-default path, for -L and for
        # the fixpoint. QA defines LIBUSED (which RTMAIN wants) and
        # itself references QBSYM; QB defines QBSYM. One sweep pulls
        # QA and leaves QBSYM undefined -- only a rescan finds QB.
        qa = (bytes([0x20, 0x00, 0x80, 0x60])
              + bytes([0x9F, 0x01, 0x00, 0x00]) + bytes([0x00])
              + bytes([0x40 | 7]) + b'LIBUSED' + bytes([0x00, 0x80])
              + bytes([0x80 | 5]) + b'QBSYM' + bytes([0x00, 0x80])
              + bytes([0x00]))
        qb = (bytes([0xEA, 0xEA, 0xEA, 0x60]) + bytes([0x00])
              + bytes([0x40 | 5]) + b'QBSYM' + bytes([0x00, 0x80])
              + bytes([0x00]))
        prodos.mkdir(f'{root}/MYLIB')
        prodos.mkdir(f'{root}/MYLIB/LIBQ')
        # QB IS WRITTEN FIRST, and the order is the entire test.
        # ProDOS lists a directory in creation order, so a single
        # sweep meets QB while QBSYM is not yet wanted, skips it,
        # then takes QA -- which is what makes QBSYM undefined. Only
        # a RESCAN comes back for QB.
        #
        # Written QA-first this test passed with the rescan
        # DELETED: one sweep took QA and then met QB with QBSYM
        # already undefined. The chain was real and the ordering
        # made it reachable in one pass, so the gate proved nothing.
        #
        # AND the same ordering now also proves PLACEMENT: taken
        # members land in DIRECTORY order at the -l's position
        # (ldscan.s LIBSPLICE), so QB -- taken second, created
        # first -- must sit at $2004, before QA. Discovery-order
        # placement puts QA first and check_ld's chain catches it.
        prodos.write(f'{root}/MYLIB/LIBQ/QB', qb, file_type=0xF8,
                     aux_type=4, overwrite=True)
        prodos.write(f'{root}/MYLIB/LIBQ/QA', qa, file_type=0xF8,
                     aux_type=4, overwrite=True)
        # -L resolving an EXPLICIT MODULE OPERAND, not a -l library
        # member (docs/BYE-SLICE1.md's unrelated ld -L work, same
        # day: OPENMOD, src/bin/ldpass.s). ONLYL is RTLIB's own
        # bytes under a name that exists NOWHERE else on this disk
        # -- not at /mnt/MAUX/ONLYL (cwd-relative, what a bare operand
        # falls back to), not under /usr/lib -- so a link that
        # finds it AT ALL proves -L's search ran, and the paired
        # run with -L omitted has NOTHING else that could make it
        # succeed by accident. That second run is the teeth: without
        # it, a linker that silently ignored -L and happened to find
        # ONLYL some other way would still pass the first.
        prodos.mkdir(f'{root}/MYMOD')
        prodos.write(f'{root}/MYMOD/ONLYL', rtlib, file_type=0xF8,
                     aux_type=68, overwrite=True)
    if LD_NAME != 'mld':
        # the argument file in the form the self-host staging writes
        # (convert.text_from_host: low ASCII, CR line ends)
        prodos.write(f'{root}/LDARGS', convert.text_from_host(
            b'-a 2000 -o /mnt/MAUX/LDOUT7\n/mnt/MAUX/RTMAIN '
            b'/mnt/MAUX/RTLIB\n'), file_type=0x04, aux_type=0x0000,
            overwrite=True)
        prodos.write(f'{root}/LDARGS2', convert.text_from_host(
            b'-a 2000 -o /mnt/MAUX/LDOUT8 /mnt/MAUX/RTMAIN '
            b'/mnt/MAUX/RTLIB\n'), file_type=0x04, aux_type=0x0000,
            overwrite=True)
        # The length boundary (review F6): blanks in front, so the
        # last word is the file's last byte. Lengths are asserted on
        # the converted bytes, not trusted.
        def argfile(name, out, size):
            tail = (f'-a 2000 -o /mnt/MAUX/{out} /mnt/MAUX/RTMAIN '
                    f'/mnt/MAUX/RTLIB').encode()
            data = convert.text_from_host(b' ' * (size - len(tail)) + tail)
            assert len(data) == size, (name, len(data), size)
            prodos.write(f'{root}/{name}', data, file_type=0x04,
                         aux_type=0x0000, overwrite=True)
        argfile('LDARGS3', 'LDOUT9', 1022)
        argfile('LDARGS4', 'LDOUT10', 1023)
        argfile('LDARGS5', 'LDOUT11', 63)
    prodos.write(f'{root}/BIN/{_LD}', ldbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/RTLIB', rtlib, file_type=rtlib_type,
                 aux_type=rtlib_aux, overwrite=True)
    prodos.write(f'{root}/RTMAIN', rtmain, file_type=rtmain_type,
                 aux_type=rtmain_aux, overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-ld] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-ld] kept={kept} removed={removed}')
    print(f'[build-ld] wrote MAUX.SYSTEM ({len(system)}B), SH ({len(shbin)}B), '
          f'LD ({len(ldbin)}B), RTLIB ({len(rtlib)}B), '
          f'RTMAIN ({len(rtmain)}B), SCRIPT ({len(SCRIPT_BYTES)}B)')
    print(f'[build-ld] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
