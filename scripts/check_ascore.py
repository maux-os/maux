#!/usr/bin/env python3
"""check_ascore.py -- task #8 phase B acceptance gate (`make check-ascore`).

Drives the PATCHED Merlin assembler core and asserts docs/AS-DESIGN.md
section 2/5b's phase-B criteria:

  (a) PACKOP2.S assembles to completion headless, 0 errors, with a POISON
      keystroke (a space, the stock pagination-pause trigger) deliberately
      latched during the run -- the patched core must complete anyway,
      proving P4's neutering. Completion is detected by control reaching
      ASEXIT (P5's landing pad), the same until_pc technique
      check-asmspike uses for ASMBLER.
  (b) the assembled object (aux $A000, OBJPNT's hardcoded default as of
      P11, docs/AS-DESIGN.md section 15/16 -- moved from $8000 to buy the
      source/symtab window 8K) is byte-identical to the shipped stock
      object vendor/merlin/PACKOP2. P11 only relocates WHERE the object
      lands, never what it contains, so this stays a straight compare.
  (c) the symbol table lands in P1's main-bank window ($2000-$9FFF, P11-
      enlarged) and the old aux home is untouched: aux $1000-$9FFF and
      aux $A100-$C6FF (i.e. everything the stock symtab could reach,
      minus the $A000 object page the core legitimately still writes)
      show ZERO writes.
  (d) divergence audit: every staged source is byte-identical to a fresh
      re-derivation from vendor/merlin/ + src/merlin/patches.py, with
      per-file byte-delta accounting printed, and PARMS carries the P2
      bytes ($83 at 4, $00 at 13).
  (e) P7: assembling TESTDSK.S (which carries a `DSK TDSKOBJ` directive)
      creates NO file -- the dispatch is a clean no-op.

THE PIPELINE ACTUALLY REBUILDS THE CORE (the vacuous-test guard). An
earlier draft of this gate booted build/ascore.po and drove PACKOP2
directly -- but the image BOOTS the stock prebuilt /SOURCE/MERLIN.SYSTEM,
so every assertion was exercising the STOCK core and the patches were
never in the loop (caught when the P1-reverted sabotage produced
identical results to the patched build). The gate therefore:

  1. audits the staged sources (d) -- host-side, fails fast;
  2. boots the image and runs the full STEPBYSTEP rebuild (reusing
     check_merlin_build.py's proven drivers) so the four objects are
     assembled FROM THE PATCHED SOURCES by the stock core;
  3. host-side, verifies the bound /SOURCE/MERLIN.SYSTEM (SAVE/MERLIN
     binds over the BOOT FILE; /SOURCE/SAVE/MERLIN.SYSTEM is the shipped
     stock reference) is NOT byte-identical to that stock reference, and
     that ASEXIT's self-jump exists in the built AS object (found by
     scan, its address is layout-derived, never hardcoded) and is the
     target of exactly one other JMP (SYMPRINT's P5 redirect); copies
     the artifacts to build/ -- after the bind the image already boots
     the patched core, no swap step exists;
  4. reboots and asserts (a)/(b)/(c) driving PACKOP2, then (e) driving
     TESTDSK in a second boot.

Because step 3 destroys the image's stock assembler, the gate REQUIRES a
fresh `make ascore-image` before every run (the Makefile dependency does
this; running this script twice against one image is invalid).

Teeth (each watched failing -- outcomes recorded in docs/AS-DESIGN.md's
phase-B addendum): build the image with --exclude P4 / P1 / P5 / P7 or
--corrupt-packop2 / --sabotage-audit and run this gate against it with
the matching --exclude; exactly the paired assertion must fail.

--variant {hardware,process,warm} (process added task #8 phase C,
docs/AS-DESIGN.md section 13; warm added task #8 phase D, docs/
STICKY.md sec 31's cure applied to `as`): hardware is the default and
this file's ENTIRE description above still applies to it unchanged --
same image path, same artifact names, same 6/6 teeth. process gates the
P1+P10 bank-agnostic core `ld.s` embeds: same (d) divergence audit and
the same real-Merlin rebuild, against build/ascore-process.po and
build/merlin_patched_process/, producing build/ascore-process-
{merlin.system,as.obj,bank1.obj}. warm is IDENTICAL to process except
for one equate (src/merlin/patches.py's P1_SYMADR_HIGH vs
P1_SYMADR_LOW -- SYMADR moved above `as.s`'s own image end so a warm
respawn's un-recopied blobs can never overlap the symbol table), gated
against build/ascore-warm.po / build/merlin_patched_warm/, producing
build/ascore-warm-{merlin.system,as.obj,bank1.obj} -- the core `as.s`
itself embeds. Both process and warm skip (a)/(b)/(c)/(e), which assert
hardware-default RAMWRT behavior a bank-agnostic core does not
reproduce under MACED's own (hardware-default) entry. `make check-as`
is `as`'s own core's behavioral gate; `make check-ld` is `ld`'s.

--build-image (warm only, in practice): stage the variant's work disk
via build_ascore_image.py's own build() function called directly,
bypassing that script's CLI (its --variant choices do not include
`warm` -- that file is out of this task's owned scope, and its build()
already takes out_img/variant/patched_dir as plain parameters, so no
edit to it is needed). hardware/process keep using that script's CLI
directly (`ascore-image`/`ascore-process-image` in the Makefile).
"""
import argparse
import os
import re
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import check_merlin_build as cmb  # noqa: E402  (wait/settle/assemble/...)
import build_ascore_image as bai  # noqa: E402  (derive/PRIMARY/...)

sys.path.insert(0, os.path.join(ROOT, 'src', 'merlin'))
import patches  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

DEFAULT_IMAGE = os.path.join(ROOT, 'build', 'ascore.po')
DEFAULT_IMAGE_BY_VARIANT = {
    'hardware': DEFAULT_IMAGE,
    'process': os.path.join(ROOT, 'build', 'ascore-process.po'),
    # warm (task #8 phase D, docs/STICKY.md sec 31's cure applied to
    # `as`): process's own P1+P10 set with P1_SYMADR_HIGH instead of
    # P1_SYMADR_LOW -- the core `as.s` itself now embeds. `ld` keeps
    # embedding the `process` artifacts above, byte-for-byte unchanged
    # -- see src/merlin/patches.py's WARM_GROUPS header.
    'warm': os.path.join(ROOT, 'build', 'ascore-warm.po'),
}
# Where build_ascore_image.py's derived sources land for a human/audit
# diff -- only 'warm' needs a value here since it's not one of that
# script's own VARIANT_DEFAULTS keys (that file is owned by another
# engineer's build-infra scope; this dict lets check_ascore.py drive a
# THIRD variant through bai.build()'s already-generic parameters
# -- out_img/patched_dir -- without editing that file at all).
PATCHED_DIR_BY_VARIANT = {
    'warm': os.path.join(ROOT, 'build', 'merlin_patched_warm'),
}
# Artifact basenames per variant. hardware keeps the ORIGINAL names
# (docs/AS-DESIGN.md section 7/8 already have other files pointing at
# these -- as.s's own putbin paths, notably, still targeted them until
# this pass rewired it to the process names below) so nothing that
# already depends on them needs to change; process gets its own,
# unambiguous set (docs/AS-DESIGN.md section 13, ruling 2); warm gets a
# third, equally unambiguous set -- the one src/bin/as.s embeds now.
ARTIFACT_NAMES_BY_VARIANT = {
    'hardware': {
        'system': 'ascore-merlin.system',
        'as_obj': 'ascore-as.obj',
        'bank1_obj': 'ascore-bank1.obj',
    },
    'process': {
        'system': 'ascore-process-merlin.system',
        'as_obj': 'ascore-process-as.obj',
        'bank1_obj': 'ascore-process-bank1.obj',
    },
    'warm': {
        'system': 'ascore-warm-merlin.system',
        'as_obj': 'ascore-warm-as.obj',
        'bank1_obj': 'ascore-warm-bank1.obj',
    },
}
REFERENCE_OBJ = os.path.join(ROOT, 'vendor', 'merlin', 'PACKOP2')
MENU = 'L :Load source'

AS_ORG = 0xE5F0            # MACASS.S:254 ORG $E5F0 -- the AS object's base
OBJ_ADDR = 0xA000          # OBJPNT hardcoded default (ASSMAIN.S:22-24),
                           # P11-moved from $8000 to $A000 (docs/
                           # AS-DESIGN.md section 15/16); object bytes go
                           # to AUX (PUTBYT bracket kept in the hardware
                           # core -- P10 is process-only)
NEW_SYMADR = 0x2000        # P1's main-bank symtab base

# (c) snapshot ranges: everything the STOCK aux symtab could reach
# ($1000 up to FENCE's $C700), minus the $A000 object page (P11) the
# patched core still legitimately writes through the untouched PUTBYT
# bracket.
AUX_RANGES = [(0x1000, 0x9000), (0xA100, 0x2600)]
MAIN_RANGE = (NEW_SYMADR, 0x8000)   # $2000-$9FFF, below the P11 OBJPNT
                                    # ceiling ($A000) -- the enlarged
                                    # symtab/source window


def new_client():
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    c.initialize()
    for unit in range(1, 7):
        c.call_tool('eject_disk', {'unit': unit})
    return c


def boot(c, image):
    c.call_tool('reset', {'backend': 'fast'})
    r = c.call_tool('mount_disk', {'path': os.path.abspath(image)})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')
    cmb.wait(c, MENU)
    cmb.settle(c)


# --------------------------------------------------------------- (d) ----

def check_symadr_agrees():
    """`as.s`'s SYMADR equate must equal the value P1_SYMADR_HIGH patches
    into the CORE's own MACASS.S.

    THE SAME CONSTANT LIVES IN TWO LANGUAGES. The core's symbol table
    base is a patch string here; `as.s` carries its own `SYMADR equ` and
    builds its ceiling guard (`err */SYMADR`) out of it. The guard is
    only a guard while the two agree -- raise the equate alone and it
    goes on passing while the core's symtab, still at the patched
    address, grows straight through `as.s`'s arena.

    That is not hypothetical: it happened on 2026-08-28. The symbol
    table overwrote BLOBSIG, CHKBLOB saw the signature change and
    STAMPHEAD cleared the entry head ON PURPOSE (so the next `as`
    cold-loads a clean image), and the visible result was check-textaudit
    reporting ENTRY HEAD MOVED and check-as reporting every spawn cold --
    two gates, neither naming the cause, and a build that said nothing.
    """
    failures = []
    want = None
    for _f, _a, _b, _old, new_lines in patches.P1_SYMADR_HIGH:
        for line in new_lines:
            m = re.search(r'SYMADR\s*=\s*\$([0-9A-Fa-f]{1,4})', line)
            if m:
                want = int(m.group(1), 16)
    got = None
    with open(os.path.join(ROOT, 'src/bin/as.s'), errors='replace') as fh:
        for raw in fh:
            m = re.match(r'SYMADR\s+equ\s+\$([0-9A-Fa-f]{1,4})', raw)
            if m:
                got = int(m.group(1), 16)
                break
    if want is None or got is None:
        failures.append(
            f'could not read SYMADR from both sides (patches={want}, '
            f'as.s={got}) -- one of the two spellings moved or was '
            f'renamed; they must stay comparable')
    elif want != got:
        failures.append(
            f"SYMADR disagrees: src/merlin/patches.py patches the core's "
            f'MACASS.S to ${want:04X} but src/bin/as.s declares ${got:04X}. '
            f"as.s's `err */SYMADR` ceiling guard is built from ITS copy, "
            f'so while these differ the guard passes against the wrong '
            f'address and the core\'s symbol table can grow through '
            f"as.s's arena unchecked. Move BOTH or neither.")
    else:
        print(f'[check-ascore] SYMADR agrees on both sides: ${got:04X} '
              f'(patches.py -> the core, and as.s -> its own ceiling '
              f'guard)')
    return failures


def audit(image, exclude, variant='hardware'):
    """Staged-vs-derived byte equality for all seven chain sources, PARMS
    P2 assertion, and per-file byte-delta accounting. `exclude` is teeth
    on top of `variant`'s own base group set (patches.exclude_for_variant)
    -- this is what lets ONE function gate BOTH artifacts (docs/AS-DESIGN.md
    section 13, ruling 2: "the divergence audit still covers both")."""
    failures = []
    full_exclude = patches.exclude_for_variant(variant, exclude)
    vol = a2til.open_image(image)
    print(f'[check-ascore] --- (d) divergence audit (variant={variant}) ---')
    for name in bai.PRIMARY + bai.PUT_INCLUDED:
        expected, n_patch, _ = bai.derive(
            name, patches.build_all_patches(exclude=full_exclude))
        staged = vol.read_file(f'/SOURCE/{name}')
        vendor_len = os.path.getsize(os.path.join(bai.MERLIN_SRC, name))
        if bytes(staged) != expected:
            diffs = sum(1 for x, y in zip(staged, expected) if x != y) \
                + abs(len(staged) - len(expected))
            failures.append(f'(d) {name}: staged source differs from '
                            f'vendor+patchset derivation ({diffs} byte(s)) '
                            f'-- an edit outside the named patch set')
        else:
            print(f'[check-ascore]   {name:<14} {n_patch:>2} patch(es), '
                  f'{len(expected) - vendor_len:+5d}B vs vendor, staged == '
                  f'derived')
    parms = vol.read_file('/SOURCE/PARMS')
    if (len(parms) != 44
            or parms[patches.PARMS_SLOT_OFFSET] != patches.PARMS_SLOT_VALUE
            or parms[patches.PARMS_SEARCHR_OFFSET]
            != patches.PARMS_SEARCHR_VALUE):
        failures.append(f'(d/P2) PARMS wrong: len={len(parms)}, '
                        f'[4]=${parms[4]:02X} (want $83), '
                        f'[13]=${parms[13]:02X} (want $00)')
    else:
        print('[check-ascore]   PARMS          44B, [4]=$83 (never $C3), '
              '[13]=$00 -- P2 holds')
    return failures


# ------------------------------------------------------ rebuild + swap --

BANNER = re.compile(r'End assembly, \d[\d ]* bytes, Errors: (\d+)')


def find_banner(blob):
    """The REAL completion banner, not a listed source line. MACASS's
    chain includes GETLINE.S, whose `ASC "--End assembly, "00` and
    `ASC "bytes, Errors: "00` string literals scroll past IN THE LISTING
    during assembly -- a bare 'End assembly' substring match fires on
    those and reports the listing as completion (bitten 2026-08-19).
    The banner is the only line with the full assembled shape and no
    quote character."""
    for line in blob.splitlines():
        if '"' in line:
            continue
        m = BANNER.search(line)
        if m:
            return line.strip(), int(m.group(1))
    return None, None


def assemble(c, name):
    """L <name> / ASM, waiting on the real banner. Returns (line, errs)."""
    c.call_tool('type', {'text': f'L{name}\r'})
    cmb.wait(c, 'Editor')
    cmb.settle(c)
    c.call_tool('type', {'text': 'ASM\r'})
    line = errs = None
    for _ in range(200):
        c.call_tool('step', {'cycles': 4_000_000})
        line, errs = find_banner(cmb.screen(c))
        if line is not None:
            break
    if line is None:
        raise RuntimeError(f'{name}: no completion banner; screen:\n'
                           f'{cmb.screen(c)}')
    cmb.wait_quiet(c)            # let the symbol-table listing finish
    c.call_tool('type', {'text': 'Q\r'})
    cmb.wait(c, MENU)
    cmb.settle(c, 2)
    return line, errs


def rebuild_core(image):
    """Phase 2: STEPBYSTEP rebuild from the PATCHED staged sources, driven
    by the image's stock boot core. Every assembly must report Errors: 0."""
    failures = []
    print('[check-ascore] --- rebuilding core from patched sources ---')
    c = new_client()
    try:
        boot(c, image)
        for name in ('INTERPRETER', 'MACED', 'MACEXEC'):
            line, errs = assemble(c, name)
            print(f'[check-ascore]   {name:<12} {line}')
            if errs != 0:
                failures.append(f'rebuild: {name} -> {line!r}')
        cmb.disk_command(c, 'BRUN PACKOP2')
        line, errs = assemble(c, 'MACASS')
        print(f'[check-ascore]   {"MACASS":<12} {line}')
        if errs != 0:
            failures.append(f'rebuild: MACASS (the patched chain) -> '
                            f'{line!r}')
        cmb.disk_command(c, 'BRUN SAVE/MERLIN')
        print('[check-ascore]   SAVE/MERLIN bound')
    finally:
        c.close()
    return failures


def artifact_phase(image, variant='hardware'):
    """Phase 3, host-side: vacuous-test guard, ASEXIT discovery, artifact
    extraction. Returns (asexit_addr, failures). Artifact basenames come
    from ARTIFACT_NAMES_BY_VARIANT so the two cores never collide on disk
    (docs/AS-DESIGN.md section 13, ruling 2) -- hardware keeps the
    original names.

    FILE ROLES (bitten 2026-08-19, the hard way): SAVE/MERLIN binds the
    new system OVER /SOURCE/MERLIN.SYSTEM -- the boot file itself -- and
    /SOURCE/SAVE/MERLIN.SYSTEM is Willi Kusche's SHIPPED stock reference
    (that is what check_merlin_build.py's BUILT/REFERENCE constants have
    said all along). An earlier draft had the roles reversed and its
    "swap" step overwrote the freshly-bound patched core with stock; the
    gate then faithfully reported stock behavior (poison-space park,
    DSK creating its file). No swap is needed at all: after the rebuild
    the image already BOOTS the patched core."""
    failures = []
    vol = a2til.open_image(image)
    rebuilt = vol.read_file('/SOURCE/MERLIN.SYSTEM')
    stock_ref = vol.read_file('/SOURCE/SAVE/MERLIN.SYSTEM')
    as_obj = vol.read_file('/SOURCE/ASMOBJ/AS')

    # Vacuous-test guard: a gate that "passes" against the stock core is
    # not a gate (this file's own history, twice now). The bound system
    # must differ from the shipped stock reference, and P5's landing pad
    # must be IN the artifact.
    if bytes(rebuilt) == bytes(stock_ref):
        failures.append('bound MERLIN.SYSTEM is byte-identical to the '
                        'shipped stock reference -- the patches never '
                        'reached the artifact (vacuous-test guard)')

    asexit = None
    for i in range(len(as_obj) - 2):
        if as_obj[i] == 0x4C:
            target = as_obj[i + 1] | (as_obj[i + 2] << 8)
            if target == AS_ORG + i:
                asexit = target
                break
    if asexit is None:
        failures.append('no ASEXIT self-jump found in the built AS object '
                        '-- P5\'s landing pad is not in the artifact')
    else:
        refs = sum(
            1 for i in range(len(as_obj) - 2)
            if as_obj[i] == 0x4C
            and (as_obj[i + 1] | (as_obj[i + 2] << 8)) == asexit)
        if refs != 2:   # the pad itself + SYMPRINT's redirected exit
            failures.append(f'ASEXIT ${asexit:04X} has {refs} JMP refs in '
                            f'the AS object, expected 2 (pad + P5 '
                            f'redirect)')
        else:
            print(f'[check-ascore] ASEXIT discovered at ${asexit:04X} '
                  f'(self-jump + 1 redirect ref) -- P5 is in the artifact')

    names = ARTIFACT_NAMES_BY_VARIANT[variant]
    for host, guest in ((names['system'], None),
                        (names['as_obj'], '/SOURCE/ASMOBJ/AS'),
                        (names['bank1_obj'], '/SOURCE/ASMOBJ/PROASM.BANK1')):
        data = rebuilt if guest is None else vol.read_file(guest)
        with open(os.path.join(ROOT, 'build', host), 'wb') as fh:
            fh.write(bytes(data))
    print(f'[check-ascore] artifacts -> build/{names["system"]} '
          f'({len(rebuilt)}B), {names["as_obj"]}, {names["bank1_obj"]}; the '
          f'bind already replaced the boot file, next boot runs the '
          f'patched core')
    return asexit, failures


# ------------------------------------------------------- (a)(b)(c)(e) ---

def drive_packop2(image, asexit):
    """Phase 4: boot the patched core, assemble PACKOP2 with a poison
    space latched, assert (a)/(b)/(c)."""
    failures = []
    print('[check-ascore] --- (a)/(b)/(c) driving the PATCHED core ---')
    c = new_client()
    try:
        boot(c, image)
        for start, length in AUX_RANGES:
            c.call_tool('mem_diff', {'action': 'snapshot',
                                     'name': f'aux{start:04x}',
                                     'addr': start, 'len': length,
                                     'bank': 'aux'})
        c.call_tool('mem_diff', {'action': 'snapshot', 'name': 'mainsym',
                                 'addr': MAIN_RANGE[0], 'len': MAIN_RANGE[1],
                                 'bank': 'main'})
        c.call_tool('type', {'text': 'LPACKOP2\r'})
        cmb.wait(c, 'Editor')
        cmb.settle(c)
        # 'ASM\r' starts the run; the trailing space is the POISON
        # keystroke -- it latches in $C000 (stock KEYCHK's pagination
        # trigger) and stays there because the patched core never reads
        # the keyboard. NOTHING else is typed: completion must come with
        # a key latched and no further input, which is assertion (a).
        c.call_tool('type', {'text': 'ASM\r '})
        hit = c.call_tool('until_pc', {'pc': asexit,
                                       'max_cycles': 80_000_000})
        if not hit.get('hit'):
            failures.append('(a) control never reached ASEXIT -- the run '
                            'parked (P4 not effective) or crashed: '
                            f'{hit}')
            return failures
        line, errs = find_banner(cmb.screen(c))
        print(f'[check-ascore] (a) reached ASEXIT ${asexit:04X}; {line}')
        if line is None or errs != 0 or '71 bytes' not in line:
            failures.append(f'(a) bad completion banner: {line!r}')

        ref = open(REFERENCE_OBJ, 'rb').read()
        got = bytes(c.call_tool('peek', {'addr': OBJ_ADDR,
                                         'count': len(ref),
                                         'bank': 'aux'})['bytes'])
        if got != ref:
            ndiff = sum(1 for x, y in zip(got, ref) if x != y)
            failures.append(f'(b) object at aux ${OBJ_ADDR:04X} differs '
                            f'from stock PACKOP2 in {ndiff}/{len(ref)} '
                            f'byte(s)')
        else:
            print(f'[check-ascore] (b) object byte-identical to stock '
                  f'({len(ref)}B at aux ${OBJ_ADDR:04X})')

        for start, length in AUX_RANGES:
            d = c.call_tool('mem_diff', {'action': 'diff',
                                         'name': f'aux{start:04x}'})
            if d.get('changed'):
                failures.append(
                    f'(c) aux ${start:04X}-${start + length:04X} was '
                    f'written ({d["changed"]} byte(s), first at '
                    f'${d.get("first", 0):04X}) -- symtab still in aux')
            else:
                print(f'[check-ascore] (c) aux ${start:04X}-'
                      f'${start + length:04X} untouched')
        d = c.call_tool('mem_diff', {'action': 'diff', 'name': 'mainsym'})
        if not d.get('changed'):
            failures.append(f'(c) main ${MAIN_RANGE[0]:04X} window shows '
                            f'no writes -- symtab did not land in the P1 '
                            f'window')
        else:
            print(f'[check-ascore] (c) main ${MAIN_RANGE[0]:04X}+ has '
                  f'{d["changed"]} byte(s) of symtab activity '
                  f'(first ${d.get("first", 0):04X})')
    finally:
        c.close()
    return failures


def drive_testdsk(image, asexit):
    """Phase 5 (e): the DSK directive must be a no-op -- fresh boot (the
    previous run ends parked in ASEXIT's self-loop)."""
    failures = []
    print('[check-ascore] --- (e) P7: DSK directive must not open a file ---')
    c = new_client()
    try:
        boot(c, image)
        c.call_tool('type', {'text': 'LTESTDSK\r'})
        cmb.wait(c, 'Editor')
        cmb.settle(c)
        c.call_tool('type', {'text': 'ASM\r'})
        hit = c.call_tool('until_pc', {'pc': asexit,
                                       'max_cycles': 80_000_000})
        if not hit.get('hit'):
            failures.append(f'(e) TESTDSK run never reached ASEXIT: {hit}')
            return failures
        line, errs = find_banner(cmb.screen(c))
        print(f'[check-ascore] (e) {line}')
        if line is None or errs != 0:
            failures.append(f'(e) TESTDSK assembly errored: {line!r}')
    finally:
        c.close()
    names = {e.name for e in a2til.open_image(image).scandir('/SOURCE')}
    if 'TDSKOBJ' in names:
        failures.append('(e) TDSKOBJ exists on the volume -- the DSK '
                        'dispatch is NOT neutered')
    else:
        print('[check-ascore] (e) no TDSKOBJ created -- DSK is a clean '
              'no-op')
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--variant', choices=sorted(DEFAULT_IMAGE_BY_VARIANT),
                    default='hardware',
                    help='hardware (default) = today\'s check-ascore '
                         'meaning, unchanged, still gated PACKOP2/(a)-(e); '
                         'process = P1+P10\'s bank-agnostic core `ld.s` '
                         'embeds; warm = the same core with SYMADR moved '
                         'above the image end, the core `as.s` embeds -- '
                         'both audited and rebuilt the same way, but NOT '
                         'driven through (a)/(b)/(c)/(e): those assert '
                         'hardware-default RAMWRT behavior (object in aux, '
                         'PACKOP2 poison-key completion) that a bank-'
                         'agnostic core run under MACED\'s own hardware-'
                         'default entry does not reproduce -- see '
                         'docs/AS-DESIGN.md section 13. check-ld/check-as '
                         'are what prove those cores behaviorally, under '
                         'their own maux-process entry.')
    ap.add_argument('--image', default=None,
                    help='defaults to the variant\'s own path')
    ap.add_argument('--exclude', default='',
                    help='patch groups the image was built without, on '
                         'top of the variant\'s own base set (teeth runs; '
                         'must match the build)')
    ap.add_argument('--audit-only', action='store_true')
    ap.add_argument('--build-image', action='store_true',
                    help='stage the variant\'s work disk (build_ascore_'
                         'image.py\'s own build()) and exit -- the `warm` '
                         'variant\'s equivalent of running that script\'s '
                         'CLI directly with --variant hardware/process, '
                         'which its own --variant choices do not cover '
                         '(that file is out of this task\'s owned scope; '
                         'bai.build() already takes out_img/variant/'
                         'patched_dir as plain parameters, so this calls '
                         'it directly instead of editing that CLI)')
    args = ap.parse_args()
    image = args.image or DEFAULT_IMAGE_BY_VARIANT[args.variant]
    exclude = {g.strip() for g in args.exclude.split(',') if g.strip()}

    if args.build_image:
        # bai.build() applies patches.exclude_for_variant() itself --
        # pass the raw teeth set (`exclude`), not a pre-expanded one.
        return bai.build(image, variant=args.variant, exclude=exclude,
                         patched_dir=PATCHED_DIR_BY_VARIANT.get(args.variant))

    if not os.path.exists(image):
        print(f'error: {image} not found -- run `make ascore-image` '
              f'(ascore-process-image for --variant process, '
              f'ascore-warm-image for --variant warm)',
              file=sys.stderr)
        return 2

    failures = check_symadr_agrees()
    failures += audit(image, exclude, variant=args.variant)
    if args.audit_only or failures:
        for f in failures:
            print(f'[check-ascore] FAIL: {f}', file=sys.stderr)
        return 1 if failures else 0

    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2

    failures += rebuild_core(image)
    if not failures:
        asexit, art_failures = artifact_phase(image, variant=args.variant)
        failures += art_failures
        # A missing ASEXIT is a HARD failure, never a quiet skip. Until
        # 2026-08-19 this read `if asexit is not None and not failures`
        # with no else: excluding P5 left ASEXIT undiscoverable, the
        # behavioural drives (a)/(b)/(c)/(e) never ran, `failures` stayed
        # empty and the gate printed PASS -- the P5 tooth failed with no
        # FAIL line, which is how the hole was found. Same vacuous-pass
        # family as the stock-core trap this gate's header documents: a
        # gate that cannot run its assertions must say so, loudly.
        if asexit is None:
            failures.append('ASEXIT not found in the built AS object -- '
                            'P5 is missing from the artifact, so the '
                            'headless drives cannot run (this is a '
                            'failure, not a skip)')
        elif not failures and args.variant == 'hardware':
            failures += drive_packop2(image, asexit)
            failures += drive_testdsk(image, asexit)
        elif not failures:
            print(f'[check-ascore] variant={args.variant}: skipping '
                  '(a)/(b)/(c)/(e) -- those assert hardware-default RAMWRT '
                  'behavior the bank-agnostic core does not share under a '
                  'MACED-driven entry; check-as drives this core '
                  'behaviorally under its own maux-process entry instead')

    if failures:
        for f in failures:
            print(f'[check-ascore] FAIL: {f}', file=sys.stderr)
        return 1
    if args.variant == 'hardware':
        print('[check-ascore] PASS: patched core rebuilt from source, '
              'assembles headless with a poison key latched, object '
              'byte-identical, symtab in the P1 main window with aux '
              'clean, DSK neutered, divergence audit clean')
    else:
        print(f'[check-ascore] PASS (variant={args.variant}): P1+P10 core '
              'rebuilt from source by real Merlin, differs from stock, '
              'ASEXIT present, divergence audit clean -- see check-as for '
              'the behavioral proof')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
