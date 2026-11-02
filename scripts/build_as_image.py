#!/usr/bin/env python3
"""Build the ProDOS-hosted `as` acceptance-gate image (`make check-as`).

Companion to src/test/astest.s / scripts/check_as.py -- same shape as
build_sh_image.py, extended with `as` itself, a small self-contained good
module (src/test/asmodtest.s -- the SAME bytes merlin32 assembles on the
host for the reference object, staged verbatim so there is no drift
between the staged source and what check_as.py compares against), and a
source with one deliberate syntax error (src/test/asbadmod.s).

Run 1 (see astestb.s): `sh` (stdin from a staged script) runs `AS
/mnt/MAUX/GOODMOD.S -o /mnt/MAUX/GOODMOD.OBJ` -- this is the "from the maux
shell" proof (deliverable 2 asks for `as` run FROM THE MAUX SHELL) --
THEN, ADJACENTLY, the SAME assembly again into /mnt/MAUX/GOODMOD2.OBJ (the
warm-respawn proof, see SCRIPT_TEXT's own comment below), then
MULTIMOD.S, then BIGMOD.S, then `EXIT`. Run 2 (astestb.s's own "run 2"
numbering): `AS` is spawned DIRECTLY (not through sh) on the bad module
with fd 2 dup'd to a harness file, because sh.s recognizes only '<'/'>'
-- no `2>` -- so a shell script cannot capture `as`'s own stderr
diagnostic; the direct-spawn-plus-fdactions technique is the same one
src/test/lstest.s and catreadtest.s already use for exactly this reason.
"""
import os
import shutil
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXAS.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
AS_BIN = os.path.join(ROOT, 'build', 'as.bin')
GOODMOD_SRC = os.path.join(ROOT, 'src', 'test', 'asmodtest.s')
BADMOD_SRC = os.path.join(ROOT, 'src', 'test', 'asbadmod.s')
MULTIMOD_SRC = os.path.join(ROOT, 'src', 'test', 'asmultitest.s')
BIGMOD_SRC = os.path.join(ROOT, 'build', 'asbigmod.s')
PUTMOD_SRC = os.path.join(ROOT, 'src', 'test', 'asputtest.s')
RELMOD_SRC = os.path.join(ROOT, 'src', 'relspike', 'RTLIB.S#040000')
RELMAIN_SRC = os.path.join(ROOT, 'src', 'relspike', 'RTMAIN.S#040000')
PUTINC_SRC = os.path.join(ROOT, 'src', 'test', 'asputinc.s')
OUT_IMG = os.path.join(ROOT, 'build', 'as.po')

# Four `as` runs in the SAME sh script (docs/AS-DESIGN.md's task text:
# byte-identical for the simple module, asmultitest.s (multiple labels/
# forward-ref/:LOCAL), AND asbigmod.s -- the P11 proof module, LARGER
# than as.s's OLD achievable source-window capacity, section 15/16's
# requirement 5). BIGMOD runs LAST, deliberately: if a teeth run (exclude
# P11 from the embedded core) corrupts BIGMOD's own assembly, GOODMOD and
# MULTIMOD -- separate process spawns, already completed and their
# objects already on disk by then -- must still read back correct,
# isolating the P11 tooth to the big-module phase alone. All exit 0 or
# the script output alone would not distinguish which one failed --
# check_as.py reads sh's own overall exit status plus all .OBJ files
# back and diffs each independently against its own host-merlin32
# reference.
#
# THE SECOND GOODMOD LINE (docs/STICKY.md sec 31, same shape as
# build_ld_image.py lines 88-97) IS THE WARM-RESPAWN PROOF. `as` rewrites
# 8,685 of its 15,968 image bytes per run, entry `jmp` included, so lazy
# free's LZ_RETAIN refuses to retain its bank and every spawn cold-loads
# -- but nothing in this gate asserted that until now. A gate that
# cannot observe a genuinely WARM second invocation cannot see this bug
# class at all (`ld` shipped broken on exactly this hole -- sec 29/31).
# The second line is inserted IMMEDIATELY after the first, identical in
# every way except the `-o` path: ADJACENCY IS LOAD-BEARING. Anything
# spawned between the two lines can reclaim the bank and make run 2
# cold, which would pass while proving nothing -- check_as.py's
# spawn_trail() asserts the two `/bin/AS` spawns are back-to-back in
# the boot's own spawn order, not merely that both happened somewhere.
# The output is GOODMOD2.OBJ, NEVER GOODMOD.OBJ reused: if run 2 hung or
# wrote nothing, run 1's correct bytes would still be sitting under that
# name and the compare would pass vacuously. check_as.py reads GOODMOD2
# .OBJ back and compares it against the SAME host reference GOODMOD.OBJ
# is compared against (build/asmodtest.bin), never against GOODMOD.OBJ
# itself -- two identically-wrong outputs must still fail.
SCRIPT_TEXT = (
    'AS /mnt/MAUX/GOODMOD.S -o /mnt/MAUX/GOODMOD.OBJ\r'
    'AS /mnt/MAUX/GOODMOD.S -o /mnt/MAUX/GOODMOD2.OBJ\r'
    'AS /mnt/MAUX/MULTIMOD.S -o /mnt/MAUX/MULTIMOD.OBJ\r'
    'AS /mnt/MAUX/BIGMOD.S -o /mnt/MAUX/BIGMOD.OBJ\r'
    # THE PUT CASE, LIVE since 2026-08-28 (docs/AS-PUT.md's last
    # section). A module whose `put` pulls in a second file that
    # defines a label the first half references FORWARD -- so the
    # object cannot come out right unless the put loaded the right
    # bytes AND the parent resumed at the right source pointer. This
    # is the case task #8 needs: every real maux unit has several
    # `put` lines, and until this ran `as` could not assemble one.
    'AS /mnt/MAUX/PUTMOD.S -o /mnt/MAUX/PUTMOD.OBJ\r'
    # THE REL CASES (S9 REL route, docs/S9-PLAN.md sec 6 L0). The SAME
    # source bytes check-rel stages for real Merlin (src/relspike/,
    # already high-bit CR text -- RDXFORM is a fixed point on that
    # form), so the reference REL objects check-rel exports
    # (build/rtlib.rel, build/rtmain.rel -- real Merlin's own output,
    # dictionary included) are the references for the SAME input.
    # RTLIB exercises the ENT half of the dictionary (two exports, no
    # fixups); RTMAIN the EXT half (one fixup entry + one EXT symbol).
    # Their ` DSK /SOURCE/..` lines are clean no-ops under as (P7:
    # `DSK JMP RESTART`).
    'AS /mnt/MAUX/RELMOD.S -o /mnt/MAUX/RELMOD.OBJ\r'
    'AS /mnt/MAUX/RELMAIN.S -o /mnt/MAUX/RELMAIN.OBJ\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXAS.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (AS_BIN, 'as userland binary'),
        (GOODMOD_SRC, 'good test module source'),
        (PUTMOD_SRC, 'put test module source'),
        (PUTINC_SRC, 'put test include source'),
        (BADMOD_SRC, 'bad test module source'),
        (MULTIMOD_SRC, 'multi-label/forward-ref/:LOCAL test module source'),
        (BIGMOD_SRC, 'P11 big-module proof source (run scripts/'
                     'gen_asbigmod.py or `make build/asbigmod.s` first)'),
        (RELMOD_SRC, 'REL spike library module source'),
        (RELMAIN_SRC, 'REL spike main module source'),
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
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(AS_BIN, 'rb') as f:
        asbin = f.read()
    with open(GOODMOD_SRC, 'rb') as f:
        goodsrc = f.read()
    with open(BADMOD_SRC, 'rb') as f:
        badsrc = f.read()
    with open(MULTIMOD_SRC, 'rb') as f:
        multisrc = f.read()
    with open(BIGMOD_SRC, 'rb') as f:
        bigsrc = f.read()
    # THE PUT LINE IS REWRITTEN, and that is the case rather than a
    # convenience: on the image there are no relative paths, so a
    # staged unit's put carries an absolute one -- exactly what
    # build_maux_src_image.py does for the real tree. merlin32
    # assembles the host pair with the relative operand, this stages
    # the same pair with the absolute one, and the two must produce
    # the same OBJECT.
    with open(PUTMOD_SRC, 'rb') as f:
        putsrc = f.read().replace(b'put   asputinc.s',
                                  b'put   /mnt/MAUX/PUTINC.S')
    assert b'/mnt/MAUX/PUTINC.S' in putsrc, 'put-line rewrite missed'
    with open(PUTINC_SRC, 'rb') as f:
        putincsrc = f.read()
    with open(RELMOD_SRC, 'rb') as f:
        relmodsrc = f.read()
    with open(RELMAIN_SRC, 'rb') as f:
        relmainsrc = f.read()

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
    prodos.write(f'{root}/BIN/AS', asbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    # Staged VERBATIM -- the same bytes merlin32 assembles on the host
    # (scripts/check_as.py's reference), so there is nothing to keep in
    # sync by hand.
    prodos.write(f'{root}/GOODMOD.S', goodsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/BADMOD.S', badsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/MULTIMOD.S', multisrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/BIGMOD.S', bigsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/PUTMOD.S', putsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/PUTINC.S', putincsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/RELMOD.S', relmodsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/RELMAIN.S', relmainsrc, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-as] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-as] kept={kept} removed={removed}')
    print(f'[build-as] wrote MAUX.SYSTEM ({len(system)}B), SH ({len(shbin)}B),'
          f' AS ({len(asbin)}B), GOODMOD.S ({len(goodsrc)}B), '
          f'BADMOD.S ({len(badsrc)}B), MULTIMOD.S ({len(multisrc)}B), '
          f'BIGMOD.S ({len(bigsrc)}B), SCRIPT ({len(SCRIPT_BYTES)}B)')
    print(f'[build-as] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
