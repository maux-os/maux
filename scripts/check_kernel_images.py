#!/usr/bin/env python3
"""check_kernel_images.py -- size ceiling for the kernel `.SYSTEM` test
images (docs/PLAN.md "Known bugs, recorded not fixed": "The 27 .SYSTEM
kernel images are gated by NO size ceiling at all").

WHY THIS EXISTS. check_modules.py's check_image_fits() scans build/*.bin
only -- that is userland (each program's own process-bank image, checked
against IMAGE_WINDOW = the $0800-$BEFF process window). The kernel's own
acceptance-test images -- src/test/*test.s manifests that assemble a
whole bootable `.SYSTEM` binary carrying the kernel plus one harness --
are `.SYSTEM` files, not `.bin`, so check_image_fits() never looks at
them, and nothing else did either. src/kernel/process.s:53-82 recorded
the resulting invariant ("everything from $6000 up is unclaimed, inside
K_CODE_C") as STALE IN PLACE on 2026-08-23: ten of these images already
load past $6000, into the MLI io_buffer region PMLI_IBF_BASE reserves.
This module is what process.s's comment now points to.

EVERYTHING BELOW IS DERIVED, NOT ENUMERATED. There is no hardcoded list
of image names and no hardcoded $6000 or $4800 literal:

  * THE IMAGE SET. A "kernel .SYSTEM image" is a top-level manifest
    (scripts/check_manifests.py's own toplevel_manifests()) whose
    put/use closure reaches src/kernel/process.s (the same
    "process-bearing" test check_kernel_proc_mods() already runs in
    check_manifests.py), further filtered to the ones the Makefile
    itself builds to a `.SYSTEM` target (as opposed to a plain `.bin`
    -- four process-bearing manifests, argvtest.s/forktest.s/
    processtest.s/sertest.s, build to build/*.bin and are already inside
    check_image_fits()'s glob, just checked against the wrong ceiling
    for their own memory layout -- see NOTE below). This is exactly
    check_manifests.build_graph()/closure()/toplevel_manifests(),
    reused, plus the Makefile's own rules parsed with
    check_manifests.parse_makefile_vars()/parse_makefile_rules() to
    find which rule's dependency list names each manifest and produces
    a `.SYSTEM` target. Measured 2026-08-23: this derivation finds
    exactly 27 images, matching the PM's hand count -- see
    derive_kernel_images()'s docstring for the number that did NOT
    match.

  * THE CEILING. PMLI_IBF_BASE is parsed out of src/kernel/process.s's
    own `equ` line -- never typed into this file as a literal. It is
    cross-checked against inc/mm.main.equ's K_CODE_C, which
    the process.s comment cites as the same boundary under a different
    name; the two have never been observed to disagree, and if they
    ever do that is exactly the kind of drift check_modules.py's
    check_softswitch_alias() catches for the $C0xx range and nothing
    catches here, so this module fails loudly on it rather than
    silently trusting one file.

  * EACH IMAGE'S EXTENT. A ProDOS `.SYSTEM` file loads flat, starting
    at its own `org`, for exactly its file length -- so
    end address = org + built file size
    is exact, not an estimate, given a correct org and an up-to-date
    build. The `org` is parsed from the manifest's own first `org`
    directive (there is exactly one per manifest, verified by hand
    2026-08-23 across all 27 -- every one is $2000, but the parser
    reads it per-file rather than assuming that).

    WHAT WAS NOT DERIVED FROM THE ASSEMBLER'S OWN OUTPUT, AND WHY.
    merlin32 -v1 writes a `<name>_Output.txt` symbol-table dump beside
    the binary (the hygiene rule in learning:01M0M9R7RT22JEPP2R0Y6J9MBX
    says to read a moving address from exactly that dump rather than
    hardcode it). But only 5 of the 27 kernel image rules pass -v1
    today (MAUXAS, MAUXFILEPROC, LDTEST, MAUXSH, MAUXSTICKY -- the
    other 22 do not, and this module's file scope is check_image_fits()
    plus adjacent code, not a license to rewrite 22 Makefile recipes
    that other engineers own). `org + file size` does not have the
    staleness problem that hygiene rule warns about: `org` is a fixed
    policy constant the programmer chose once (like PMLI_IBF_BASE
    itself), not a PC-computed address that drifts with code size --
    the actual moving quantity here (the image's end address) is
    computed fresh from the CURRENT build's own file size every run,
    which is at least as authoritative as a symbol-table peek: the
    file size accounts for every emitted byte including any trailing
    `ds`/`hex` data with no label of its own, where a symbol-table
    lookup would only find the last *named* address.

  * THE MERLIN32 SILENT-ERROR HOLE. The PM's report of this item said
    merlin32 prints `[Error] ...` on a negative `ds` and still exits 0.
    Reproduced independently (2026-08-23, merlin32 v1.1.10 via
    Homebrew, macOS, pushing src/test/processtestb.s's `ds $5000-*`
    pad negative by 1..1655 bytes): on THIS build, merlin32 instead
    EXITS 1 and does NOT touch the normal `<name>_Output.txt` dump at
    all -- it writes a differently-named `error_output.txt` (in the
    SOURCE directory, e.g. `src/test/error_output.txt`, not `build/`)
    and leaves any prior successful build artifact untouched. The
    error text itself matches exactly ("Evaluation of DS data size
    ends up as negative value (-86)" reproduced verbatim at the same
    magnitude the PM cited), so this is not a different bug -- likely
    either a different merlin32 build/patch level behind the same
    version string, or the PM's own exit code was laundered through a
    shell pipe. Recorded as a correction, not asserted as settled --
    see this task's street-library deposit.

    Given that ambiguity, this module hedges rather than trusts either
    behaviour: it scans every `build/*_Output.txt` for a genuine
    diagnostic line (`=> [Error] ...`, merlin32's own console-message
    prefix -- NOT a bare substring match, which false-positived on
    this very docstring's own prose once it got PUT into a kernel
    image and dumped as a source-line comment) and, separately, for a
    stray `error_output.txt` anywhere under the tree, whose mere
    EXISTENCE is evidence a fatal assembly error happened and was not
    cleaned up -- the one signal that survives even when the normal
    dump is never written at all.

  * STALENESS. A `.SYSTEM` older than any file in its own manifest's
    transitive put/use closure is exactly the "stale .bin from a prior
    build defeats even the `test -f` guard" case named in this task --
    flagged, not silently trusted.

THE RATCHET DECISION (this module's answer to "what should the gate DO
about the violators"). A hard failure on all 27 images being <=
PMLI_IBF_BASE would currently redden ~11 of them (see below) for a
property process.s's own comment already says is measured-safe-today
(the overlapping tail bytes are boot-time code/data consumed before
file traffic allocates the buffer) -- that red would just get waved
through, exactly the outcome HACKING.md's "a stated constraint that is
silently broken is worse than no constraint" warns about, just moved
from "no constraint" to "an ignored one". So this is a SHRINK-ONLY
ratchet on MEMBERSHIP *and* on each member's measured overrun, in the
exact style of check_modules.py's LONG_LINE_BASELINE / check_dialect.py's
OUT_OF_SCOPE_LINE_DEBT: KNOWN_OVERRUN maps an image to the overrun in
bytes measured when this ratchet was written. A member whose overrun
GROWS beyond its recorded value fails (delta > 0); a brand-new violator
is exactly that case with an implicit baseline of 0. A member whose
overrun shrinks passes, with a note to lower the baseline -- same
courtesy LONG_LINE_BASELINE extends. A baseline entry for an image that
no longer overruns at all, or no longer exists, is stale and must be
removed, same as KNOWN_DEBT/KNOWN_DUPLICATES/SOFTSWITCH_BASELINE.

THE NUMBER (see this task's report for the full derivation): measuring
KNOWN_OVERRUN fresh on 2026-08-23 found ELEVEN images over the ceiling,
not the ten process.s's stale comment names -- MAUXSEDTEST.SYSTEM
(landed since the comment was written, task #8b's second half) is an
eleventh, +400B over. Two of the original ten also measure WORSE than
the comment's addresses (MAUXFINDTEST, MAUXDUTEST -- ~440B further
over each, from the pathname-fence RELAYOUT that landed after the
comment was written): this ratchet is pinned to freshly measured
values, not copied from the stale comment.
"""
import glob
import os
import time
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_manifests as cm  # noqa: E402 -- put/use graph + Makefile parser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ORG_RE = re.compile(r'^\s*org\s+\$([0-9A-Fa-f]+)\b', re.IGNORECASE)
EQU_HEX_TEMPLATE = r'^\s*{name}\s+equ\s+\$([0-9A-Fa-f]+)\b'


def _first_match(path, regex):
    for line in open(path, errors='replace'):
        code = line.split(';')[0]
        m = regex.match(code)
        if m:
            return int(m.group(1), 16)
    return None


def _first_dec(path, pattern):
    """Like _first_match for a DECIMAL `equ` (counts and sizes)."""
    regex = re.compile(pattern, re.IGNORECASE)
    for line in open(path, errors='replace'):
        m = regex.match(line.split(';')[0])
        if m:
            return int(m.group(1))
    return None


# Where PMLI_IBF_BASE may live. It was src/kernel/process.s's own
# `equ` line until S9 L4 (2026-08-30) hoisted the kernel's
# cross-module equates into inc/ -- an equate two REL modules
# both name cannot cross the Merlin linker, so it had to become a
# put file. SEARCHED, not hardcoded to one path: this gate died
# outright when the symbol moved, which is exactly the
# stale-second-copy failure its own docstring warns about.
PMLI_IBF_SOURCES = ('inc/proc.const.equ', 'src/kernel/process.s')


def get_pmli_ibf_base():
    """PMLI_IBF_BASE -- the io_buffer base that IS the kernel image
    ceiling, parsed from whichever file currently declares it."""
    regex = re.compile(EQU_HEX_TEMPLATE.format(name='PMLI_IBF_BASE'),
                       re.IGNORECASE)
    tried = []
    for rel_path in PMLI_IBF_SOURCES:
        path = os.path.join(ROOT, rel_path)
        tried.append(rel_path)
        if not os.path.exists(path):
            continue
        val = _first_match(path, regex)
        if val is not None:
            return val
    raise RuntimeError(
        f'PMLI_IBF_BASE not found in any of {tried} -- cannot derive '
        f'the kernel image ceiling. If it moved again, add its new '
        f'home to PMLI_IBF_SOURCES.')


def get_kcode_c_base():
    """K_CODE_C, parsed from inc/mm.main.equ -- the same $6000
    boundary under memmap.equ's own name, cross-checked against
    PMLI_IBF_BASE rather than trusted as identical by assumption."""
    path = os.path.join(ROOT, 'inc/mm.main.equ')
    regex = re.compile(EQU_HEX_TEMPLATE.format(name='K_CODE_C'),
                        re.IGNORECASE)
    return _first_match(path, regex)


def get_manifest_org(path):
    """The manifest's own load address -- its first `org` directive.
    ProDOS SYSTEM files load flat starting here, so this plus the built
    file's size is the image's exact memory extent."""
    return _first_match(path, ORG_RE)


def derive_kernel_images(graph):
    """{manifest_path: built_target_path} for every top-level manifest
    that (a) reaches src/kernel/process.s in its put/use closure -- the
    same process-bearing test check_manifests.check_kernel_proc_mods()
    already runs -- and (b) the Makefile builds to a `.SYSTEM` target.
    (b) is what separates this set from the four process-bearing
    manifests (argvtest.s, forktest.s, processtest.s, sertest.s) that
    build to a plain `.bin` and are already covered, if imprecisely, by
    check_image_fits()."""
    put_targets = {t for edges in graph.values() for _d, t, _l in edges}
    manifests = cm.toplevel_manifests(graph, put_targets)
    process_s = os.path.normpath(os.path.join(ROOT, 'src/kernel/process.s'))
    process_bearing = {m for m in manifests if process_s in cm.closure(graph, m)}

    text = open(os.path.join(ROOT, 'Makefile'), errors='replace').read()
    raw_vars = cm.parse_makefile_vars(text)
    rules = cm.parse_makefile_rules(raw_vars, text)

    def norm(tok):
        return os.path.normpath(os.path.join(ROOT, tok))

    images = {}
    for targets, deps in rules:
        # a pattern target (`build/MAUX%.SYSTEM`, the play block's
        # grouped-target rule, Makefile) is a recipe, not an image: the
        # image itself is named by the explicit `$(PLAYTESTBLK):` line
        sys_targets = [t for t in targets
                       if t.endswith('.SYSTEM') and '%' not in t]
        if not sys_targets:
            continue
        dep_paths = {norm(d) for d in deps}
        for m in dep_paths & process_bearing:
            images.setdefault(m, set()).update(norm(t) for t in sys_targets)
    return images, process_bearing


# Shrink-only ratchet, house style (LONG_LINE_BASELINE / OUT_OF_SCOPE_LINE_DEBT):
# image basename -> overrun in BYTES past PMLI_IBF_BASE, measured 2026-08-23
# against a from-scratch build (`make build/<name>.SYSTEM` per image). A
# member whose overrun grows past this, or a member not listed at all
# overrunning by any amount, fails. Values here are what THIS ratchet
# measured, not copied from src/kernel/process.s's stale comment -- see
# this module's docstring for the two names that disagree and why, and
# MAUXSEDTEST, the one name in this set the comment does not have at all.
#
# RE-PINNED AT MERGE, 2026-08-23, and this is a DECISION rather than a
# bump. MAUXDIFFTEST and MAUXTAIL each grew EXACTLY +40 bytes when the
# poison work added the `WAIT_GO` between-run handshake to their
# harnesses (src/test/difftestb.s, src/test/tailtestb.s): a 4-line park
# plus two lines per call site, and this gate priced it at 40 B a
# harness. Both images were ALREADY over the ceiling (66 B and 347 B),
# so the growth pushed two existing violators deeper into the io_buffer
# region rather than creating new ones.
#
# The trade was accepted deliberately, by the integrator, for a stated
# reason: that handshake IS the between-run re-poison, and without it a
# pre-boot poison is consumed by run 1 while runs 2..N execute on run
# 1's residue (measured: tail's six runs all reused bank 2). Proving
# five programs write-before-read is worth 40 bytes in a region where
# another image is already 2,710 B over. Reverting is one line per
# entry if that judgement is wrong.
#
# What is NOT acceptable is this growing silently, which is the whole
# point of the ratchet -- it made a 40-byte decision visible, in a
# region nobody was watching, within one merge of the gate landing.
#
# RE-PINNED AGAIN, 2026-08-23, +14 B each, MAUXEXPR and MAUXTESTEV
# ONLY -- not a bump, a fleet-wide fix's known, one-off cost. MKPATH
# (src/liba/mli.s) used to truncate an over-length pathname SILENTLY:
# no carry, no error, count byte rewritten to 64 -- and on hardware
# that 64-byte prefix named a real, different, SHORTER directory, so
# the caller's next MLI call SUCCEEDED against the wrong object
# (docs/E2E.md sec 10.6 finding 1, sec 10.13). The fix sets carry AND
# overwrites the last copied byte with $00, a byte no real ProDOS
# catalog entry can contain, so the pathname can no longer match
# anything and the caller's own next MLI call fails cleanly instead
# of lying -- fail-CLOSED, closing the defect for all 29 MKPATH
# callers, only 5 of which checked its length first. That fix costs
# +14 B in liba/mli.s, and liba is put WHOLE into every image that
# reaches it, so +14 B lands in every one of the 27 kernel images
# whose put/use closure includes src/liba/mli.s -- verified
# (check_manifests.closure()) to be exactly two of the eleven
# over-ceiling images: MAUXTESTEV (testevtestb.s puts mli.s directly)
# and MAUXEXPR (exprtestb.s puts mli.s directly). The other nine
# over-ceiling images do not reach mli.s in their closure and did not
# move (confirmed: delta 0 for all nine after a from-scratch rebuild).
# Neither +14 crosses a real boundary: MAUXTESTEV's new end ($6247)
# stays inside io_buffer 1 ($6000-$63FF, buffer-boundary margin
# 440 B); MAUXEXPR's new end ($6AA4) stays inside io_buffer 3
# ($6800-$6BFF, margin 347 B); both stay far short of PMLI_XFER_BUF
# ($7800). The MKPATH fix itself was read for a cheaper encoding of
# the same fail-closed guarantee (same carry, same $00 poison) and
# found already tight -- see src/liba/mli.s's own header.
# -- RE-PINNED 2026-08-25, +58 B on every member, plus one new member.
# -- CAUSE: SYS_DUP2 (call 9) -- PRC_DUP2 and the shared PRC_DUP2_SET
# -- in src/kernel/procfd2.s. It is in EVERY kernel image because the
# -- dispatch table is now shared (src/kernel/kdisp.s), so every image
# -- carries a vector for call 9 and therefore the handler.
# --
# -- WAS IT AVOIDABLE? The handler was already written twice as small
# -- as its first draft: oldfd's range check, open check and fetch are
# -- all delegated to procfd.s's existing PRC_CUR_FDOBJ, and the
# -- close/refcount/set tail is SHARED with spawn()'s fdactions rather
# -- than duplicated -- that factoring gave PRC_FDACTIONS 17 B back.
# -- 58 B is a new syscall handler plus a shared core, and the only
# -- way to zero is not to have dup2, which is what blocks subshells
# -- (docs/SH-SUBSHELL.md, docs/SHELL-GAPS.md sec 1).
# --
# -- MARGIN CHECK, in the style of the MKPATH note below: the worst
# -- new end is MAUXEXPR at $6AF7, inside io_buffer 2 ($6800-$6BFF,
# -- margin 265 B), and every member stays far short of
# -- PMLI_XFER_BUF ($7800). No member crossed into a buffer it was
# -- not already in.
# --
# -- AND THE TREND NOTE BELOW NOW APPLIES TO A SECOND CAUSE. It was
# -- written about liba changes landing on the mli.s consumers. This
# -- is a KERNEL change landing on ALL of them at once, which is the
# -- worse shape: every future process syscall costs every image,
# -- and SYS_TICK (docs/SHELL-GAPS.md sec 5) is already planned. The
# -- question that note says to ask -- whether these harnesses should
# -- carry a put/use chain this size -- is now due for the kernel
# -- side too, not just exprtest/testevtest.
# -- ALL TWELVE RE-PINNED 2026-08-26, +144B each (MAUXPLAY +170).
# -- SYS_TICK (docs/SHELL-GAPS.md sec 5) added PRC_TICK and
# -- PRC_TICKFTCH to procfile3.s, which every kernel harness links;
# -- MAUXPLAY pays 26B more because it also links timer.s, whose
# -- tick counter went 16- to 32-bit and grew three carry chains.
# -- This is the trend note below arriving exactly as predicted: a
# -- KERNEL change lands on ALL of them at once. It also went
# -- UNNOTICED for a commit, because SYS_TICK was landed after
# -- running check-sched/check-env/check-fleet/check-modules and NOT
# -- check-all -- the ratchet had no chance to speak until the next
# -- full sweep, which is the argument for sweeping before
# -- committing a kernel change rather than after.
KNOWN_OVERRUN = {
    # -- 2026-10-08 (docs/KSPACE-NOTES.md): EMPTY. Homing 1,006 B of
    # -- scratch cells in low main freed that much in every image;
    # -- MAUXEXPR (+659) and MAUXEDTEST (+363) are now 347 and 643 B
    # -- UNDER the ceiling. The pins below are gone with them, and the
    # -- table is back to its shrink-only floor of zero entries.
    # -- 2026-09-14: the FIRST entry since the table emptied. PRC_TMD_RST
    # -- (procspawn2.s) now also resets the live console's escape parser
    # -- when a writer is force-killed mid-sequence -- 10 B in every
    # -- image; MAUXEXPR was the one sitting at exactly 0 B slack after
    # -- the 2026-09-13 merge trims. A kernel byte cannot be paid for
    # -- with a byte-trim in a routine whose tails (PRC_FAIL_A/
    # -- PRC_RET_OK0) own the stack frame, so this is a pin with its
    # -- reason, SHRINK-ONLY like every entry this table ever held. It
    # -- goes back to 0 the day exprtest's put chain loses 10 B.
    # -- RAISED to 14 the same day: PRC_REAP_ORPH (process2.s) now
    # -- also reaps a ZOMBIE orphan (a background subshell's exited
    # -- grandchild whose killer parent already died), not just a
    # -- STOPPED one -- +4 B (one extra cmp/beq/bne) in every image,
    # -- measured directly (MAUXEXPR.SYSTEM 30730 -> 30734 B).
    # -- RAISED to 30 the same day: PRC_KILL (procspawn2.s) now
    # -- also refuses the CONSOLE SHELL (operator ruling, "the
    # -- cheap one" -- docs/POSIX-GAPS.md sec 7) -- one grandparent
    # -- PCB read (PRDPAR_FIELD) plus a compare, +16 B in every
    # -- image, measured directly (MAUXEXPR.SYSTEM 30734 -> 30750 B).
    # -- 2026-09-15, the posix-sed <- main merge: main's K_IDLE_PID
    # -- scheduler (idle runs only when nothing else can, 748f12b)
    # -- met posix-sed's job-control/wake-preemption kernel; the
    # -- two grew every image, MAUXEXPR by +38 B (30750 -> 30793),
    # -- measured directly. Re-pinned at what the merged tree
    # -- measures; the image's io_buffer 8 slack absorbs it.
    # -- RAISED to 86 the same merge's own regression fix
    # -- (docs/JOB-CONTROL.md, ^Z foreground-stop): KRN_EXIT
    # -- patches the OUTGOING process's frame (FRAME_A/FRAME_P)
    # -- indexed by K_CALLER_SP, but a handler that runs its own
    # -- SCH_SWITCH before returning (PRC_STOP's cooperative ^Z)
    # -- leaves BANKSEL/K_CURBANK naming the INCOMING pid by
    # -- then -- the patch landed in the wrong bank's memory,
    # -- and when caller depth + FRAME_A's offset happened to
    # -- equal the incoming pid's own depth + FRAME_Y's offset
    # -- it silently zeroed that pid's saved call number,
    # -- turning its very next syscall into ERR_NOSYS. Fixed by
    # -- snapshotting the caller's bank at KRN_ENTRY
    # -- (K_CALLER_BANK, entry.s, ordinary main memory like
    # -- K_CALLER_SP -- a zero-page placement at $F2, the one
    # -- byte docs/MEMMAP.md's "$EF-$F2 unclaimed" row actually
    # -- had free (the other three, $EF-$F1, turned out to
    # -- already be sched.s's K_CWD_PTR/K_CWD_TMP -- a separate
    # -- stale-doc bug fixed the same commit), hung boot for a
    # -- reason not chased down; reverted to plain `ds 1`,
    # -- proven booting, rather than spend more of this task's
    # -- budget on a 3-byte saving) and restoring it in KRN_EXIT
    # -- before the frame patch -- +13 B in every image (2 abs
    # -- LDA/STA touching K_CURBANK/BANKSEL, 2 abs LDA/STA on
    # -- the new cell, 1 B of storage), measured directly
    # -- (MAUXEXPR.SYSTEM 30793 -> 30806 B).
    # -- RAISED to 89 the same day: K_CALLER_BANK's own read of
    # -- K_CURBANK broke src/test/syscalltest.s and
    # -- bankcopytest.s -- those two spikes `put` entry.s +
    # -- sched.equ but never sched.s, and K_CURBANK was a `ds`
    # -- cell declared INSIDE sched.s (undefined symbol,
    # -- merlin32 "Impossible to decode address mode"). Moved
    # -- K_CURBANK's `ds` into entry.s, alongside K_SWITCH/
    # -- K_TARGETBANK/K_TARGETSP (same idiom, same reason:
    # -- sched.s keeps every write, entry.s only needs the
    # -- symbol to exist), and gave it the same INSTALL_COPY
    # -- safe-zero default K_SWITCH already gets, for a spike
    # -- that never calls SCH_INIT -- +3 B (one more `stz abs`
    # -- in INSTALL_COPY, universal), measured directly
    # -- (MAUXEXPR.SYSTEM 30806 -> 30809 B).
    # -- RAISED to 94 the same day: narrowed the restore to
    # -- fire only when a handler's own SCH_SWITCH actually ran
    # -- (`lda K_SWITCH; beq` guard before the BANKSEL patch) --
    # -- SCH_SWITCH's own tail is the only writer of a nonzero
    # -- K_SWITCH, and nothing clears it before this read, so a
    # -- spike with no scheduler at all never sets it either,
    # -- leaving BANKSEL exactly as untouched as before this
    # -- whole fix. +5 B in every image (one more `lda abs` +
    # -- `beq`), measured directly (MAUXEXPR.SYSTEM
    # -- 30809 -> 30814 B).
    # -- RAISED to 151 the same day, REPLACING the KRN_ENTRY
    # -- snapshot entirely (the K_CALLER_BANK cell and its
    # -- `lda K_CURBANK / sta K_CALLER_BANK` at the top of
    # -- KRN_ENTRY are GONE): those two extra instructions ran
    # -- on EVERY syscall, unswitched or not, and shifted the
    # -- interrupt-nesting window enough to turn KRN_IRQ_ENTRY's
    # -- own documented ServeMouse re-entrancy hazard (this
    # -- file's "RIG FINDING") into a deterministic FRAME_A
    # -- corruption under the posix-sed utilities' own build
    # -- layout -- check-iobuf's "duplicate" case, RED only on
    # -- the combined tree, GREEN with either half alone or with
    # -- the snapshot replaced by two NOPs. Root cause isolated
    # -- by the coordinator's own bisection, not by reasoning
    # -- about the snapshot's bytes. Replaced with a LAZY lookup
    # -- entirely inside KRN_EXIT's existing K_SWITCH!=0 branch:
    # -- K_SW_OUTPID (moved from sched.s to sched.equ, same
    # -- reason K_CURBANK was tried and reverted -- entry.s's
    # -- two schedulerless spikes need the symbol to exist) is
    # -- the caller whenever a switch ran, and its PCB_BANK is
    # -- looked up with PCB_PTR_FOR/PCB_RD_FIELDS's own
    # -- arithmetic inlined (those two routines are sched.s-
    # -- only). The ordinary, unswitched syscall path is now
    # -- BYTE-FOR-BYTE what it was before this whole fix -- zero
    # -- cost on the hot path, so it cannot perturb the nesting
    # -- window that broke check-iobuf. All the growth lands in
    # -- the K_SWITCH!=0 branch, which no image's hot path ever
    # -- takes: +57 B net over the previous (94) pin, measured
    # -- directly (MAUXEXPR.SYSTEM 30814 -> 30871 B).
    # -- RAISED to 157 on 2026-09-16 by the ^L reprompt fix
    # -- (tty3.s): an empty line's break is the ECHOED input CR at
    # -- the line commit, which never tapped TTY_SHDW_TAP, so each
    # -- blank Enter appended to the ^L prompt-replay shadow and the
    # -- prompt came back as "$ $ $ $" on one row. Both line commits
    # -- now clear the shadow after echoing the CR -- +6 B in every
    # -- kernel image (kernel 28,896 -> 28,902), measured directly
    # -- (MAUXEXPR.SYSTEM 30871 -> 30877 B). Same shape as every pin
    # -- above it: a KERNEL byte lands on all 28 images at once and
    # -- MAUXEXPR is the one with no slack, and it cannot be paid for
    # -- inside the tap (the two stores ARE the fix). check-expr is
    # -- green on this image -- the overrunning tail is exprtest's
    # -- boot-time bytes, consumed before file traffic allocates the
    # -- io_buffer, the same measured-safe-today property the entries
    # -- above rest on. Goes back down the day exprtest's put chain
    # -- loses bytes.
    # -- RAISED to 171 on 2026-09-16 by TTY_SHDW_SPN (procfd.s), the
    # -- span form of the ^L replay shadow: TTY_RUN tapped it with a
    # -- jsr PER BYTE, which a cycle-exact decomposition of the write
    # -- path (docs/PROCIO.md sec 15) found to be the largest named
    # -- cost of putting bytes on the glass -- 910 entries and 35,521
    # -- cycles on a 23-line page, 14% of the call, plus the 6 cycles
    # -- a byte the encode loops spent round-tripping the raw byte
    # -- through PRC_BYTE to hand it over. +14 B in every kernel image
    # -- (MAUXEXPR.SYSTEM 30877 -> 30891 B), measured directly, and
    # -- the ONLY entry in this table bought with a number: 27,659
    # -- cycles off a `man cut` page on the card (279.3 -> 248.9
    # -- cyc/byte, -10.9%), i.e. ~1,976 cycles returned per byte
    # -- spent, and -4.3%/-7.0% on native-80/40-column. It cannot be
    # -- paid for inside the routine -- the routine IS the saving, and
    # -- it already replaced more bytes than it added (two encode
    # -- loops each shed a store, a jsr and a reload; the net is 14,
    # -- not the 34 the new code weighs).
    # -- RAISED to 176 on 2026-09-16 by PRC_CANONPATH's empty-path
    # -- guard (procfd2.s): `lda PRC_PATHBUF / beq :cant`, 5 B. The
    # -- routine tested PRC_PATHBUF+1 without first testing the LENGTH
    # -- byte, so for a zero-length path -- which is legal to hand the
    # -- kernel, bare `cd` is one -- the branch was chosen by the
    # -- PREVIOUS call's leftover byte, and when that leftover was '/'
    # -- the absolute arm returned carry CLEAR with PRC_CANLEN = 0. A
    # -- zero-length identity compares unequal to every saved path, so
    # -- PRC_FILE_BUSY reported NOT BUSY and the allocator was free to
    # -- park a victim for an open that could not succeed -- the
    # -- open-file guard silently off. Gated by check-iobuf's new
    # -- `nullpath` mode. 5 B is the whole fix and it cannot be paid
    # -- for locally; PRC_ABSPATH (procfd.s) has carried the same two
    # -- instructions, for the same reason, since it was written.
    # -- RAISED to 219 on 2026-09-20 by the language-card BANK
    # -- restore (docs/LANGUAGE-CARD.md): the kernel now saves the
    # -- interrupted process's LC bank at each door and puts it back
    # -- on the three switch-in/resume paths, so a process preempted
    # -- inside liba stdio's bank bracket no longer resumes with
    # -- someone else's bank selected and write its remaining
    # -- buffered bytes into the wrong 4 KB bank. +43 B in every
    # -- image, measured directly (MAUXEXPR.SYSTEM 30896 -> 30939).
    # -- The storage itself costs ZERO image bytes: the cell lives in
    # -- the PROCESS's own zero page ($FF, inc/entry.frame.equ), which
    # -- is what makes it per-process without a pid-indexed table.
    # -- MARGIN CHECK, house style: the new end is $98DB, inside the
    # -- SAME io_buffer this image already sat in ($9800, 1024 B, so
    # -- 804 B of margin remain) and far short of PMLI_XFER_BUF
    # -- ($B800). No member crossed into a buffer it was not already
    # -- in. NOTE for whoever raises this next: the note below records
    # -- a previous cross-door cell that was tried in MAIN zero page
    # -- at $F2 and hung the boot. This one is in the PROCESS's zero
    # -- page, read back only after the exit path's own `sta
    # -- ALTZPAUX`, and is sanctioned in check-altzp as XBANK(zp) --
    # -- a different placement with a different argument, not the
    # -- same idea retried.
    # -- RAISED to 385 on 2026-09-20 by SYS_VCSTAT (call 21,
    # -- PRC_VCSTAT in procfile3.s), which lazy virtual consoles
    # -- need: `chvt N` must not drop a person onto a console
    # -- nobody reads, and must not stack a SECOND shell on one
    # -- that already has one (docs/COVER-OFF.md). +166 B in
    # -- every image: a PCB scan, a VC_COUNT staging buffer and
    # -- the BankCopy out, plus two dispatch-table bytes.
    # -- ATTACHMENT is the property it reports, which is why it
    # -- is a kernel scan and not a userland PSTAT walk -- a
    # -- shell is asleep on its tty only while it is at a
    # -- prompt, and not while it runs a command, which is
    # -- exactly when someone switches away and back.
    # -- MARGIN CHECK: the new end is $9981, still inside the
    # -- io_buffer this image already sat in ($9800, 1024 B, so
    # -- 638 B of margin) and far short of PMLI_XFER_BUF
    # -- ($B800). Two harness images ALSO needed their
    # -- block-boundary pads bumped the same day (argvtest
    # -- $7800 -> $8000 / 56 -> 60 blocks, processtest $8200 ->
    # -- $8400 / 61 -> 62) -- the trend note below arriving
    # -- again, exactly as it predicts: a kernel change lands on
    # -- all of them at once.
    # -- RAISED to 431 on 2026-09-20 by the Option-1..4 console
    # -- hotkey (TTY_KEYIN's chord, VC_HOTREQ and TTY_VC_PEND --
    # -- docs/CONSOLE.md). +46 B in every image. The key only
    # -- RECORDS the request: TTY_KEYIN runs from the tick, and
    # -- VC_SWITCH blits a 24x80 screen, so performing it there
    # -- would cost ticks by the handful on every switch.
    # -- MARGIN: end $99AF, still inside the io_buffer this
    # -- image already sat in ($9800, 1024 B, 592 B of margin),
    # -- far short of PMLI_XFER_BUF ($B800).
    # -- 431 -> 447 the same day: scoping the Option control-fold
    # -- to LETTERS costs 16 B of range checks, and buys back the
    # -- four digit chords the console hotkey looked like it was
    # -- taking. End $99BF, 576 B of margin left in the buffer.
    # -- 447 -> 467 the same day: TTY_VC_PEND now refuses to move
    # -- the glass to a console with no shell (PRC_VCSCAN, split
    # -- out of PRC_VCSTAT for it). 20 B, and it is the fix for a
    # -- WEDGE the operator hit on first use -- Option-2 before
    # -- any `chvt 2` left the glass where nothing was awake to
    # -- move it back. End $99D3, 556 B of margin in the buffer.
    # -- 467 -> 544, 2026-09-21: SYS_HALT (PRC_HALT, procfile3.s)
    # -- -- `shutdown`. 77 B in every image, and it buys the one
    # -- thing this machine could not do: stop without losing
    # -- what ProDOS had not written back. End $9A20, 480 B of
    # -- margin left in the buffer.
    # -- 544 -> 575, 2026-09-21: expr grew a PAREN level (EX_PRIM
    # -- recursing to EX_OR), 31 B. End $9A3F, 449 B of margin left.
    # -- RAISED to 630, bye slice 1 (2026-09-25, e99fac4): entry.s/
    # -- entry2.s gained K_BYE_VEC/PRC_BYE_STUB/BYE_UNWIRE -- the
    # -- SYS_BYE dispatch indirection (docs/BYE-SLICE1.md gap 4) --
    # -- +55 B in every image that links entry.s, which is all of
    # -- them. NOT PAYABLE BY A TRIM: the bytes are the price of the
    # -- indirection itself (an unconditional `jmp (vector)` plus its
    # -- fail-stub default, entry.s's own P8_DELEGATE/PRODOS_UNWIRE/
    # -- K_PRODOS_VEC shape), not slack left over from something
    # -- else. WHAT IT BUYS: 30 of 31 kernel-call harnesses stopped
    # -- linking procbye.s's own dependency closure at all (entry2/
    # -- ffpage/sched/sched2/bankcopy/process/process2/procfile2-4)
    # -- -- the fix that cleared nas-librel's LINEMAX and sh's argv
    # -- MAXARGV walls for every harness but playtest (the one image
    # -- that genuinely needs `bye`). RETURNS TO BASELINE the day
    # -- kdisp.s gains a general absent-handler mechanism (so a
    # -- syscall slot with no real handler no longer needs its own
    # -- named stub pair per call) and the per-call K_BYE_VEC/
    # -- PRC_BYE_STUB/BYE_UNWIRE machinery goes away. Measured
    # -- directly (MAUXEXPR.SYSTEM 31350B, end $9A76, 7562 B of
    # -- margin left before PMLI_XFER_BUF $B800).
    # -- RAISED to 642, PRC_RAMDIS fix (2026-09-26, 802edf5): the /RAM
    # -- protocol's two REFUSAL cases (procmli.s) plus splitting
    # -- PRC_HALT into PRC_HALT/PRC_HALT_CORE (procfile3.s, so the
    # -- refusal can reuse the real halt instead of inventing a
    # -- second one) -- +12 B in every image that links both files,
    # -- which is all of them. NOT PAYABLE BY A TRIM: this is the
    # -- actual fix for a kernel that was silently claiming aux
    # -- memory it had already confirmed either does not exist or
    # -- belongs to another program -- see NOTES-BYE.md and learning:
    # -- 01KW1GTYH4NRG0F8M7AAT6EG9Z. Measured directly (MAUXEXPR.
    # -- SYSTEM 31362B, end $9A82, 7550 B of margin left before
    # -- PMLI_XFER_BUF $B800). No return-to-baseline condition --
    # -- this fix is permanent, unlike the PRC_BYE_STUB indirection
    # -- above.
    # -- RAISED to 646, second save bank for the annex (2026-09-26,
    # -- docs/BYE.md's ruling): K_BYE_BANK2 (entry.s) needs the SAME
    # -- unconditional zero-at-boot containment K_BYE_BANK already
    # -- has in entry2.s's INSTALL_COPY (some harnesses put entry2.s
    # -- without ever putting procbye.s) -- +4 B in every image that
    # -- links entry.s/entry2.s, which is all of them. NOT PAYABLE BY
    # -- A TRIM, same shape as the two raises just above: 1 B of new
    # -- storage plus a 3-byte `stz` absolute. Measured directly
    # -- (MAUXEXPR.SYSTEM 31366B, end $9A86, 646 B past
    # -- PMLI_IBF_BASE).
    # -- RAISED to 648, bye console-corruption fix (2026-09-27,
    # -- 99e49f8): the BYE_TTYRES trampoline (tty7.s) reasserts the
    # -- console's own display mode on bye's return path, +6 B in
    # -- every image that links tty7.s (which is all of them except
    # -- the three schedtest harnesses -- checked directly). Paid
    # -- back to +2 net by two `stz BANKSEL` conversions in sched.s
    # -- (SCH_RESUME/SCH_SWITCH's `:cancel` path, both `lda #0/sta`
    # -- where A is dead by the next instruction regardless) -- NOT
    # -- fully payable by a trim: exprtest.s does not link tty7.s's
    # -- console stack at all differently from any other image, so
    # -- this +2 B is the same universal kernel cost every other
    # -- entry in this table records, not something local to fix.
    # -- Measured directly (MAUXEXPR.SYSTEM 31368B, end $9A88, 648 B
    # -- past PMLI_IBF_BASE).
    # -- RAISED to 721, docs/KSEG.md DECISION 1 (2026-09-27, 5d9b585):
    # -- do/fin conditional assembly retired (nas has no D_DO/D_FIN,
    # -- src/asm/nas.pla:39-61) in favor of MODULE CHOICE -- every
    # -- full-kernel manifest that is NOT the segment (playtest.s) now
    # -- puts src/kernel/procdevs.s, a small stub carrying the OFT_BLK
    # -- glue labels (PRC_BLK_RD_G/WR_G/SM_G/GM_G/GE_G, PDEV_TRYBLK_G)
    # -- as real `jmp PDEV_NOBLK` trampolines (an EQUATE alias would
    # -- not survive REL export, df5524a), plus the five 7 B dispatch
    # -- additions (procfile3.s/procmli.s/procmli3.s) and the 6 B
    # -- PRC_DEVOPEN hook that are now UNCONDITIONAL, always-present
    # -- bytes in every image (the spec's own accepted "+35 B dispatch
    # -- + 6 B hook" cost, docs/DEV-BLOCK.md). +73 B in every image
    # -- that links procfile5.s, which is all of them. NOT PAYABLE BY
    # -- A TRIM: this is the dialect fix itself (nas is the assembler
    # -- of record; a construct it cannot assemble cannot gate the
    # -- feature). Measured directly (MAUXEXPR.SYSTEM rebuilt clean,
    # -- 31441B, end $9AD1, 721 B past PMLI_IBF_BASE).
    # -- RAISED to 771, docs/DEVFS.md (2026-09-30): SYS_ONLINE's
    # -- PRC_FILECALL dispatch entry, K_DISP_COUNT 23->24 (kdisp.s,
    # -- SYS_DEVLIST's slot), procdevs.s's four new ERR_NOSYS/
    # -- carry-only stub bodies (PRC_DEVLIST/PRC_ROOTLIKE/
    # -- PRC_SYNAPPLY/PRC_ONLINE -- the non-play manifests never
    # -- reach the real segment-resident bodies), and PRC_DOTDOT's
    # -- added PRC_ROOTLIKE short-circuit (procfile4.s) are all
    # -- UNCONDITIONAL dispatch glue in every image that links
    # -- procfile.s/procfile4.s/kdisp.s, which is all of them --
    # -- +50 B. NOT PAYABLE BY A TRIM: the four real bodies are
    # -- already segment-resident (kdevblk.s, reached via flat
    # -- KSEG_CALL trampolines only from procdev.s, the play-only
    # -- manifest); what lands here is the dispatch shape every
    # -- sibling delegate already uses, not a body that could move.
    # -- Measured directly (MAUXEXPR.SYSTEM rebuilt clean, 31491B,
    # -- end $9B03, 771 B past PMLI_IBF_BASE).
    # -- NEW ENTRY 2026-09-20, same cause: MAUXEDTEST had 0 B of
    # -- slack and SYS_VCSTAT took it. End $9891, 145 B into the
    # -- same io_buffer, 879 B of margin left in it.
    # -- 145 -> 191 the same day, same +46 B hotkey cause.
    # -- 227 -> 304, 2026-09-21: the same 77 B of SYS_HALT.
    # -- End $9930, 720 B of margin left in the buffer.
    # -- RAISED to 334, bye slice 1 (2026-09-25, e99fac4): the SAME
    # -- K_BYE_VEC/PRC_BYE_STUB/BYE_UNWIRE dispatch indirection as
    # -- MAUXEXPR.SYSTEM above -- +30 B in every image, same "not
    # -- payable by a trim" reason, same "30 of 31 harnesses stopped
    # -- linking procbye.s's closure" payoff, same return-to-baseline
    # -- condition (a general kdisp.s absent-handler mechanism).
    # -- Measured directly (MAUXEDTEST.SYSTEM 31054B, end $994E,
    # -- 7858 B of margin left before PMLI_XFER_BUF $B800).
    # -- RAISED to 346, PRC_RAMDIS fix (2026-09-26, 802edf5): the /RAM
    # -- protocol's two REFUSAL cases (procmli.s) plus splitting
    # -- PRC_HALT into PRC_HALT/PRC_HALT_CORE (procfile3.s, so the
    # -- refusal can reuse the real halt instead of inventing a
    # -- second one) -- +12 B in every image that links both files,
    # -- which is all of them. NOT PAYABLE BY A TRIM: this is the
    # -- actual fix for a kernel that was silently claiming aux
    # -- memory it had already confirmed either does not exist or
    # -- belongs to another program -- see NOTES-BYE.md and learning:
    # -- 01KW1GTYH4NRG0F8M7AAT6EG9Z. Measured directly (MAUXEDTEST.
    # -- SYSTEM 31066B, end $995A, 7846 B of margin left before
    # -- PMLI_XFER_BUF $B800). No return-to-baseline condition --
    # -- this fix is permanent, unlike the PRC_BYE_STUB indirection
    # -- above.
    # -- RAISED to 350, same K_BYE_BANK2 cause as MAUXEXPR.SYSTEM
    # -- above -- +4 B in every image. Measured directly
    # -- (MAUXEDTEST.SYSTEM 31070B, end $995E, 350 B past
    # -- PMLI_IBF_BASE).
    # -- RAISED to 352, same BYE_TTYRES cause as MAUXEXPR.SYSTEM
    # -- above (2026-09-27, 99e49f8) -- +2 B net, same accounting.
    # -- Measured directly (MAUXEDTEST.SYSTEM 31072B, end $9960,
    # -- 352 B past PMLI_IBF_BASE).
    # -- RAISED to 425, same docs/KSEG.md DECISION 1 cause as
    # -- MAUXEXPR.SYSTEM above (2026-09-27, 5d9b585) -- the same +73 B
    # -- of unconditional OFT_BLK dispatch/glue (procdevs.s stub +
    # -- five 7 B dispatch sites + 6 B PRC_DEVOPEN hook) lands in every
    # -- image that links procfile5.s. NOT PAYABLE BY A TRIM, same
    # -- reason. Measured directly (MAUXEDTEST.SYSTEM rebuilt clean,
    # -- 31145B, end $99A9, 425 B past PMLI_IBF_BASE).
    # -- RAISED to 475, same docs/DEVFS.md cause as MAUXEXPR.SYSTEM
    # -- above (2026-09-30) -- the same +50 B of unconditional
    # -- SYS_ONLINE/SYS_DEVLIST dispatch glue lands in every image
    # -- that links procfile.s/procfile4.s/kdisp.s. Measured directly
    # -- (MAUXEDTEST.SYSTEM rebuilt clean, 31195B, end $99DB, 475 B
    # -- past PMLI_IBF_BASE).
    # -- EMPTY, AND THAT IS THE POINT. 2026-08-30: every one of the
    # -- 27 images came in under the ceiling for the first time,
    # -- each by exactly 14,336 B, when PMLI_IBF_BASE moved $6000 ->
    # -- $9800 (inc/proc.const.equ has the derivation). This
    # -- table held 27 entries the day before, the largest 4,207 B.
    # --
    # -- WHAT THE DEBT ACTUALLY WAS. A ProDOS .SYSTEM image loads
    # -- FLAT from $2000 and grows up, so the first allocation above
    # -- it is its ceiling -- and that was the io_buffers at $6000,
    # -- capping every kernel image at 16,384 B. K_CODE_C is
    # -- $6000-$C000 and used 6,656 B of its 24,576, so the room was
    # -- always there; nobody had moved the buffers into it.
    # -- mm.mlibuf.equ has carried "future graphics/BASIC
    # -- display-owner work should relocate MLI buffers into
    # -- non-video main slack first" as a written debt since task
    # -- #11.
    # --
    # -- The overruns this table recorded were NOT harmless, which
    # -- is worth stating because for a year they behaved as though
    # -- they were: an image survived only while the code pushed
    # -- into the buffer range happened not to be reached before an
    # -- overlapping buffer was allocated. That is luck, and it ran
    # -- out -- 438 B of `ds`, no code whatsoever, wedged MAUXPLAY's
    # -- boot with a blank screen and no shell prompt, while `ds
    # -- 220` booted fine.
    # --
    # -- KEEP IT EMPTY. A new entry here means an image has grown
    # -- past $9800 with 30,720 B to play with, and the answer is
    # -- almost certainly to shrink the image rather than to pin it.
    # --
    # -- 2026-09-08, EMPTY AGAIN. For most of one day this held ONE
    # -- entry, MAUXEXTEST.SYSTEM, pinned at 284, then 581, then
    # -- 1026 B as three kernel increments (vi alt-screen, job-
    # -- control A and B) each landed on the same span. WHAT THE
    # -- BYTES WERE: fixture/script text embedded in the ex harness
    # -- (extestb3.s's EXSRC_TEXT.. plus extestb5..9.s's siblings,
    # -- 37 files' worth) inside the PARENT_PROC span that
    # -- extestb.s BankCopies into bank 1 at boot and reads only
    # -- from there, so the main-memory original that io_buffer 1
    # -- overlapped was dead once installed and check-ex stayed
    # -- green -- latent by ORDERING, not safe by construction,
    # -- which is why it was pinned and not hidden. RETIRED by
    # -- staging every one of those files onto ex.po at build time
    # -- from scripts/build_ex_image.py (FIXTURES, byte-identical
    # -- to what the harness used to write) and deleting the text
    # -- and its create/open/write/close plumbing from the harness:
    # -- MAUXEXTEST went from $9C02 (+1026) to well under the
    # -- ceiling in one commit, and the harness now only OPENS its
    # -- fixtures. Two things learned on the way, worth keeping:
    # -- (1) the retirement was declined once as "a half-day" --
    # -- it was not; a golden dump of the old image's *_TEXT bytes
    # -- (listing addresses -> image slices) made the Python table
    # -- verifiable without an emulator, and the box ran check-ex
    # -- once. (2) WHAT THIS RATCHET DOES NOT COVER: the image is
    # -- copied to bank 1 at its own addresses, and extestb9.s
    # -- keeps a RESULT block there ($A800-$AEFF now; it was
    # -- $9800-$9EFF) that a growing image tail can walk into --
    # -- check-ex goes red (step 40, $40) while this ratchet,
    # -- correctly, reports main memory only.
}

#: TREND, worth stating because the ratchet records levels and not
#: direction: these two entries are the mli.s consumers in the overrun
#: set, and liba changes land on them EVERY time. Two MKPATH changes in
#: two days moved them +174 each (+14 fail-closed, +160 dot paths).
#: Re-pinning is the sanctioned response to legitimate growth and is
#: what happened here -- but re-pinning is not free: MAUXEXPR is now
#: 2,884 bytes INTO the MLI io_buffer region, and the ratchet only
#: refuses SURPRISE. Nothing here says when the debt becomes unpayable.
#: If a third liba change lands on these, the question to ask is not
#: "what is the new number" but whether exprtest.s/testevtest.s should
#: still be carrying a put/use chain this size at all.


def check_kernel_image_ceiling():
    """The ratchet itself: each of the 27 derived kernel `.SYSTEM` images
    against PMLI_IBF_BASE, membership and per-image overrun pinned at
    KNOWN_OVERRUN's recorded values."""
    failures = []
    print()
    print('[check-modules] kernel .SYSTEM image ceiling (derived from '
          'process-bearing manifests + PMLI_IBF_BASE, docs/PLAN.md '
          '"27 .SYSTEM kernel images")')

    ceiling = get_pmli_ibf_base()
    kcode_c = get_kcode_c_base()
    # -- WAS AN EQUALITY UNTIL 2026-08-30, and the equality was
    # -- right while it held: K_CODE_C and PMLI_IBF_BASE both named
    # -- $6000, and drifting apart would have been a silent bug.
    # -- Moving the io_buffers to $9800 makes them legitimately
    # -- different -- K_CODE_C is the REGION ($6000-$C000), the
    # -- buffers are now a location INSIDE it -- so the invariant
    # -- becomes containment. That is strictly stronger than the
    # -- equality it replaces: it still catches the drift the old
    # -- check was for, and additionally catches buffers placed
    # -- below their own region or run up into ProDOS's global
    # -- page at $BF00.
    PRODOS_GLOBAL_PAGE = 0xBF00
    if kcode_c is not None and ceiling < kcode_c:
        failures.append(
            f'inc/proc.const.equ: PMLI_IBF_BASE is ${ceiling:04X}, '
            f'BELOW inc/mm.main.equ\'s K_CODE_C (${kcode_c:04X}) -- '
            f'the MLI io_buffers must live inside the non-video kernel '
            f'region, not under it. Exactly the class '
            f'check_softswitch_alias() catches for $C0xx; nothing else '
            f'catches it here.')
    if ceiling >= PRODOS_GLOBAL_PAGE:
        failures.append(
            f'inc/proc.const.equ: PMLI_IBF_BASE is ${ceiling:04X}, at '
            f'or above ProDOS\'s global page (${PRODOS_GLOBAL_PAGE:04X}). '
            f'The io_buffers, the xfer buffer and the lending store have '
            f'to fit BELOW it.')
    # -- 2026-09-07: the main-memory layout above the kernel image is
    # -- now THREE things that must not overlap or touch $BF00:
    # -- MLI_IOBUF_CNT io_buffers from PMLI_IBF_BASE, the xfer buffer
    # -- (PMLI_XFR_SIZE at PMLI_XFER_BUF), and the io_buffer lending
    # -- store (OFT_COUNT x OFT_SLOT_SZ at OFT_SLOT_BASE). Every
    # -- number parsed, none mirrored.
    proc_const = os.path.join(ROOT, 'inc/proc.const.equ')
    dec_tmpl = r'^\s*{name}\s+equ\s+(\d+)\b'
    xfer = _first_match(proc_const, re.compile(
        EQU_HEX_TEMPLATE.format(name='PMLI_XFER_BUF'), re.IGNORECASE))
    xfer_size = _first_match(proc_const, re.compile(
        EQU_HEX_TEMPLATE.format(name='PMLI_XFR_SIZE'), re.IGNORECASE))
    slot_base = _first_match(proc_const, re.compile(
        EQU_HEX_TEMPLATE.format(name='OFT_SLOT_BASE'), re.IGNORECASE))
    slot_sz = _first_dec(proc_const, dec_tmpl.format(name='OFT_SLOT_SZ'))
    canon = _first_match(proc_const, re.compile(
        EQU_HEX_TEMPLATE.format(name='PRC_CANON'), re.IGNORECASE))
    ibf_cnt = _first_dec(os.path.join(ROOT, 'inc/mm.mlibuf.equ'),
                         dec_tmpl.format(name='MLI_IOBUF_CNT'))
    oft_count = _first_dec(os.path.join(ROOT, 'inc/mm.annex2.equ'),
                           dec_tmpl.format(name='OFT_COUNT'))
    if None in (xfer, xfer_size, slot_base, slot_sz, canon, ibf_cnt,
                oft_count):
        failures.append(
            f'could not parse the main-memory layout constants '
            f'(PMLI_XFER_BUF={xfer}, PMLI_XFR_SIZE={xfer_size}, '
            f'OFT_SLOT_BASE={slot_base}, OFT_SLOT_SZ={slot_sz}, '
            f'PRC_CANON={canon}, MLI_IOBUF_CNT={ibf_cnt}, '
            f'OFT_COUNT={oft_count}) -- a '
            f'symbol moved; follow it rather than dropping the check')
    else:
        ibf_end = ceiling + ibf_cnt * 1024
        xfer_end = xfer + xfer_size
        slot_end = slot_base + oft_count * slot_sz
        canon_end = canon + 65        # PRC_CANON is 65 bytes
        if slot_end > canon:
            failures.append(
                f'the lending store ({oft_count} x {slot_sz} B from '
                f'${slot_base:04X}) ends at ${slot_end:04X}, into the '
                f'canonical-path scratch PRC_CANON (${canon:04X}) -- '
                f'raising OFT_COUNT means moving PRC_CANON too')
        if canon_end > PRODOS_GLOBAL_PAGE:
            failures.append(
                f'PRC_CANON (${canon:04X}+65) ends at ${canon_end:04X}, '
                f'in or past ProDOS\'s global page '
                f'(${PRODOS_GLOBAL_PAGE:04X})')
        if ibf_end > xfer:
            failures.append(
                f'{ibf_cnt} io_buffers from ${ceiling:04X} end at '
                f'${ibf_end:04X}, past PMLI_XFER_BUF (${xfer:04X}) -- '
                f'raising MLI_IOBUF_CNT means moving the xfer buffer too')
        if xfer_end > slot_base:
            failures.append(
                f'the xfer buffer (${xfer:04X}+${xfer_size:04X}) runs into '
                f'the lending store at OFT_SLOT_BASE (${slot_base:04X})')
        if slot_end > PRODOS_GLOBAL_PAGE:
            failures.append(
                f'the lending store ({oft_count} x {slot_sz} B from '
                f'${slot_base:04X}) ends at ${slot_end:04X}, in or past '
                f'ProDOS\'s global page (${PRODOS_GLOBAL_PAGE:04X})')
        if ibf_cnt > 8:
            failures.append(
                f'MLI_IOBUF_CNT is {ibf_cnt}: ProDOS 8 allows at most '
                f'EIGHT open files (TRM p.13), so buffers past the eighth '
                f'can never be used -- the kernel lends instead '
                f'(docs/IOBUF-LENDING.md)')
        print(f'   main memory above the image: {ibf_cnt} io_buffers '
              f'${ceiling:04X}-${ibf_end - 1:04X}, xfer ${xfer:04X}-'
              f'${xfer_end - 1:04X}, lending store ${slot_base:04X}-'
              f'${slot_end - 1:04X}, global page ${PRODOS_GLOBAL_PAGE:04X}')

    graph, _put_targets = cm.build_graph()
    images, process_bearing = derive_kernel_images(graph)

    if len(images) != 27:
        print(f'   NOTE: derivation found {len(images)} kernel .SYSTEM '
              f'image(s), not the 27 docs/PLAN.md names -- the tree has '
              f'moved. See the list below before assuming the count is '
              f'wrong.')

    rows = []
    missing_build = []
    seen_targets = set()
    for manifest, targets in images.items():
        org = get_manifest_org(manifest)
        if org is None:
            failures.append(
                f'{cm.rel(manifest)}: no `org` directive found -- cannot '
                f'derive its load address, so its extent cannot be '
                f'checked against PMLI_IBF_BASE.')
            continue
        for target in sorted(targets):
            name = os.path.basename(target)
            seen_targets.add(name)
            if not os.path.exists(target):
                missing_build.append(cm.rel(target))
                continue
            size = os.path.getsize(target)
            end = org + size
            overrun = end - ceiling
            baseline = KNOWN_OVERRUN.get(name, 0)
            delta = overrun - baseline
            rows.append((name, cm.rel(manifest), org, size, end, overrun,
                        baseline, delta))

    if missing_build:
        failures.append(
            f'{len(missing_build)} kernel .SYSTEM image(s) not built -- '
            f'run `make ' +
            ' '.join(sorted(missing_build)) +
            '` before this check can measure them: ' +
            ', '.join(sorted(missing_build)))

    for name, manifest, org, size, end, overrun, baseline, delta in \
            sorted(rows):
        mark = ''
        if overrun > 0:
            mark = f'  OVER by {overrun}B'
        if delta > 0:
            mark += f'  WORSE than baseline {baseline}B by {delta}B'
            failures.append(
                f'{name} (org ${org:04X} + {size}B = ${end:04X}): '
                f'{overrun}B past PMLI_IBF_BASE (${ceiling:04X}), up from '
                f'the {baseline}B recorded in KNOWN_OVERRUN -- either a '
                f'brand-new violator (baseline 0) or an existing one that '
                f'grew. {manifest} put/use chain grew into the MLI '
                f'io_buffer region.')
        elif delta < 0 and baseline:
            mark += f'  IMPROVED from baseline {baseline}B by {-delta}B -- ' \
                    f'lower KNOWN_OVERRUN'
        print(f'   {name:22} org ${org:04X}  {size:6d}B  end ${end:04X}  '
              f'overrun {overrun:+6d}B{mark}')

    stale = set(KNOWN_OVERRUN) - seen_targets
    if stale:
        failures.append(
            f'KNOWN_OVERRUN lists {sorted(stale)} but the derivation no '
            f'longer finds them among the 27 kernel .SYSTEM images -- '
            f'remove the stale entries so the ratchet stays honest.')

    over_count = sum(1 for r in rows if r[5] > 0)
    print(f'[check-modules] {len(rows)} kernel .SYSTEM image(s) measured, '
          f'{over_count} over PMLI_IBF_BASE (${ceiling:04X}), '
          f'{len(KNOWN_OVERRUN)} pinned in KNOWN_OVERRUN')
    return failures


# merlin32's own console diagnostic line looks like (verbatim, 2026-08-23
# reproduction): "      => [Error] Error : Evaluation of DS data size ends
# up as negative value (-86) : '$5000-ozunid_321' (line 719, file
# 'processtestb.s')." -- always prefixed with `=>` after leading
# whitespace. A bare substring match on `[Error]` is NOT safe: a source
# comment that happens to mention the same bracketed text (this module's
# own docstring did, once it was quoted back at itself in a kernel
# image's dump as a "Comment" source-line row) matches too, and that row
# never starts with `=>` -- it starts with a pass/line-number field.
OUTPUT_ERROR_RE = re.compile(r'^\s*=>\s*\[Error\]')


DUMP_WAIT_S = 5


def read_dump(path):
    """The lines of a merlin32 dump, or None if it stays missing.

    A parallel sweep assembles other images while this gate scans (the
    scan globs build/*_Output.txt, and merlin32 recreates a dump while it
    writes it): a file listed a moment ago can be absent at open time,
    which used to end the gate in a FileNotFoundError traceback (2 of the
    last 3 Mac sweeps, 2026-10-20). Wait up to DUMP_WAIT_S for it to come
    back; a dump that never does is a reported failure, not a pass."""
    for _ in range(DUMP_WAIT_S * 2 + 1):
        try:
            with open(path, errors='replace') as fh:
                return fh.readlines()
        except FileNotFoundError:
            time.sleep(0.5)
    return None


def check_output_errors():
    """Gate, two signals: (1) a genuine merlin32 diagnostic line in any
    build/*_Output.txt dump that happens to exist; (2) the mere EXISTENCE
    of a stray `error_output.txt` anywhere under the tree, which is what
    merlin32 writes INSTEAD of the normal dump on a fatal error (verified
    2026-08-23 -- see this module's top docstring) -- so signal (2) is
    the one that survives when a failed assemble never touched the
    normal dump at all."""
    failures = []
    print()
    print('[check-modules] merlin32 error scan (diagnostic lines in '
          'build/*_Output.txt, plus stray error_output.txt files)')
    dumps = sorted(glob.glob(os.path.join(ROOT, 'build/*_Output.txt')))
    total = 0
    for path in dumps:
        lines = read_dump(path)
        if lines is None:
            failures.append(f'{cm.rel(path)}: listed, then gone for '
                            f'{DUMP_WAIT_S:g} s -- a concurrent assemble '
                            f'left no dump behind; rerun the gate alone.')
            continue
        for n, line in enumerate(lines, 1):
            if OUTPUT_ERROR_RE.match(line):
                total += 1
                failures.append(
                    f'{cm.rel(path)}:{n}: {line.strip()} -- a merlin32 '
                    f'diagnostic survived into its own dump; only this '
                    f'scan catches it.')
    if not dumps:
        print('   0 build/*_Output.txt present -- nothing to scan (run '
              'the -v1 rules first)')
    elif total == 0:
        print(f'   0 -- {len(dumps)} dump(s) scanned, no `=> [Error]` '
              f'line in any')
    else:
        print(f'   {total} `=> [Error]` line(s) across {len(dumps)} '
              f'dump(s)')

    strays = sorted(glob.glob(os.path.join(ROOT, '**/error_output.txt'),
                              recursive=True))
    if strays:
        for path in strays:
            failures.append(
                f'{cm.rel(path)}: a stray merlin32 error_output.txt -- '
                f'its EXISTENCE means some assemble run here failed '
                f'fatally and was never cleaned up. Investigate, fix the '
                f'source, then remove this file.')
        print(f'   {len(strays)} stray error_output.txt file(s) found: '
              f'{", ".join(cm.rel(p) for p in strays)}')
    else:
        print('   0 stray error_output.txt files under the tree')
    return failures


def check_staleness(graph, images):
    """Gate: a built `.SYSTEM` older than any file in its own manifest's
    transitive put/use closure is a stale artifact -- exactly what
    defeats the Makefile's `test -f` guard on a re-run that assembled
    nothing new."""
    failures = []
    print()
    print('[check-modules] kernel .SYSTEM staleness (built artifact vs. '
          'its own put/use closure)')
    total = 0
    checked = 0
    for manifest, targets in sorted(images.items()):
        sources = cm.closure(graph, manifest)
        for target in sorted(targets):
            if not os.path.exists(target):
                continue
            checked += 1
            tmtime = os.path.getmtime(target)
            newer = sorted(s for s in sources
                           if os.path.exists(s) and os.path.getmtime(s) > tmtime)
            if newer:
                total += 1
                failures.append(
                    f'{cm.rel(target)}: older than '
                    f'{", ".join(cm.rel(s) for s in newer[:5])}'
                    f'{" ..." if len(newer) > 5 else ""} -- stale build; '
                    f're-run `make {cm.rel(target)}` before trusting its '
                    f'size against PMLI_IBF_BASE.')
    if total == 0:
        print(f'   0 -- {checked} built kernel .SYSTEM image(s) are at '
              f'least as new as every file in their own put/use closure')
    else:
        print(f'   {total} stale image(s) found')
    return failures


PT_HOLD_MANIFEST = 'src/test/playtestb.s'
PT_HOLD_IMAGE = 'MAUXPLAY.SYSTEM'
PT_HOLD_ORG_MANIFEST = 'src/test/playtest.s'
# docs/KSEG.md, coordinator review 2026-09-27: the kernel cold segment
# (byelaunch.s, PRC_BYE/PRC_RAMRECONN/PRC_RAMREDISC, the nine OFT_BLK
# bodies) plus the KSEG_LOAD/KSEG_CALL loader mechanism measured at
# EXACTLY 256 B of headroom below PT_HOLD once landed -- see
# docs/KSEG-NOTES.md's byte-accounting rounds. Pinned as a ratchet floor,
# not just a report: check_pt_hold_headroom() fails if headroom drops
# below this.
PT_HOLD_HEADROOM_FLOOR = 256

# Every harness result cell, and the gate that reads it. The asm name is
# the key; the value is (gate file, the Python constant's name). These
# cells are spread across four scripts, which is exactly how a 2026-09-20
# relocation moved four of them and left eleven at the old address.
PT_CELLS = {
    'PT_HOLD':   ('scripts/check_play.py', 'PT_HOLD_ADDR'),
    'PT_READY':  ('scripts/check_play.py', 'PT_READY_ADDR'),
    'PT_GO':     ('scripts/check_play.py', 'PT_GO_ADDR'),
    'PT_HOLD2':  ('scripts/check_play.py', 'PT_HOLD2_ADDR'),
    'PT_N80':    ('scripts/check_play80n.py', 'PT_N80_ADDR'),
    'PT_N80B':   ('scripts/check_play80n.py', 'PT_N80B_ADDR'),
    'PT_VC':     ('scripts/check_vc.py', 'PT_VC_ADDR'),
    'PT_VC2':    ('scripts/check_vc.py', 'PT_VC2_ADDR'),
    'PT_F40':    ('scripts/pt_f40.py', 'PT_F40_ADDR'),
    'PT_F40B':   ('scripts/pt_f40.py', 'PT_F40B_ADDR'),
    'R_VC_DONE': ('scripts/check_vc.py', 'R_VC_DONE'),
    'R_VC_ERR':  ('scripts/check_vc.py', 'R_VC_ERR'),
    'R_VC_STEP': ('scripts/check_vc.py', 'R_VC_STEP'),
    'R_VC_CK':   ('scripts/check_vc.py', 'R_VC_CK'),
    'R_VC_CKA':  ('scripts/check_vc.py', 'R_VC_CKA'),
}
# R_VC_CK and R_VC_CKA are lo/hi pairs -- the block's true top is the
# last cell's address plus its width.
PT_CELL_WIDTH = {'R_VC_CK': 2, 'R_VC_CKA': 2}

# The block's RETIRED home. check_play.py says of itself "copied, not
# imported: check_play is a 2,700-line program, not a library", and that
# is true of these constants too: PT_F40 alone had been hand-copied into
# fifteen scripts. Moving the four cells one file declared left eleven
# behind in the others, and the second relocation left fifteen MORE
# behind in gates that had never been read. So the gate does not just
# compare declared names -- it sweeps every script for a literal in the
# vacated range, which is the only check that sees a copy nobody named.
PT_RETIRED = ((0x9300, 0x9317),     # 2026-09-20 home
              (0x97E8, 0x97FF))     # 2026-10-10..21 home (B1 moved it)
# Two scripts legitimately use $9300 for a DIFFERENT image: bankcopytest
# (4,096 B) and writelanding, neither of which can reach it. And
# check_ibf_ceiling.py names the $97E8 block as HISTORY: its control
# plants the same padding against the old layout to show it is refused.
PT_RETIRED_OK = ('check_bankcopy.py', 'experiment_writelanding.py',
                 'check_ibf_ceiling.py')
PT_ADDR_RE = re.compile(r'0x([0-9A-Fa-f]{4})')


def check_pt_hold_headroom():
    """MAUXPLAY.SYSTEM's harness parks its HOLD/READY/GO handshake and
    every suite's verdict at FIXED main-memory addresses ABOVE the
    image, poked and peeked by the gates from the host. Nothing tied
    those addresses to the image that grows toward them.

    2026-09-20: the block sat at $9300-$9317 while the image ended at
    $9295 -- 107 bytes of headroom, inside the image's own growth room,
    with PMLI_IBF_BASE ($9800) the only ceiling written down anywhere.
    About 100 bytes of new code in playtestb.s loaded straight over it.
    FIFTEEN gates failed on BOTH hosts with `timed out waiting for
    TTY_VT_SUITE checkpoint (READY)`, which names the escape-sequence
    battery and not the collision; and when only the first four cells
    were moved, the battery then read back BLANK, because the image was
    sitting on its verdict cells instead. Replacing the new code with
    `ds N` of the same size reproduced each failure identically, which
    is learning:01M197TY462D8ZRJHSQ77FGWK9's own one-run diagnostic --
    that learning's closing section is about test harnesses parking
    result cells at fixed main addresses, and says to record the number
    next to the buffer constant. This is that record, with teeth.

    Three assertions, because the pair can drift three ways: the image
    must END below the lowest cell; every gate's Python constant must
    EQUAL the assembler's `equ`; and the block must stay below
    PMLI_IBF_BASE, so it never migrates into the io_buffer pool.
    """
    failures = []
    manifest = os.path.join(ROOT, PT_HOLD_MANIFEST)
    cells = {}
    for name in PT_CELLS:
        val = _first_match(manifest, re.compile(
            EQU_HEX_TEMPLATE.format(name=name), re.IGNORECASE))
        if val is None:
            failures.append(
                f'{name} not found in {PT_HOLD_MANIFEST} -- a harness '
                f'result cell was renamed or removed without updating '
                f'PT_CELLS, so this check can no longer bound the image')
        else:
            cells[name] = val
    if not cells:
        return failures

    for name, addr in sorted(cells.items(), key=lambda kv: kv[1]):
        gate_rel, const = PT_CELLS[name]
        gate = os.path.join(ROOT, gate_rel)
        py = _first_match(gate, re.compile(
            r'^' + const + r'\s*=\s*0x([0-9A-Fa-f]{1,4})\s*$',
            re.MULTILINE))
        if py is None:
            failures.append(f'{const} not found in {gate_rel}')
        elif py != addr:
            failures.append(
                f'{gate_rel} reads {const} = ${py:04X} but '
                f'{PT_HOLD_MANIFEST} declares {name} = ${addr:04X} -- the '
                f'gate is poking or peeking a byte the boot never touches')

    low = min(cells.values())
    high = max(addr + PT_CELL_WIDTH.get(name, 1)
               for name, addr in cells.items())
    ceiling = get_pmli_ibf_base()
    if high > ceiling:
        failures.append(
            f'the harness result block ends at ${high:04X}, at or past '
            f'PMLI_IBF_BASE (${ceiling:04X}) -- the gates are reading '
            f'bytes the MLI io_buffer pool owns')

    scripts_dir = os.path.join(ROOT, 'scripts')
    for fn in sorted(os.listdir(scripts_dir)):
        if not fn.endswith('.py') or fn in PT_RETIRED_OK:
            continue
        if fn == os.path.basename(__file__):
            continue
        with open(os.path.join(scripts_dir, fn), encoding='ascii',
                  errors='replace') as fh:
            for lineno, line in enumerate(fh, 1):
                for hit in PT_ADDR_RE.findall(line):
                    addr = int(hit, 16)
                    hole = [r for r in PT_RETIRED if r[0] <= addr <= r[1]]
                    if hole:
                        lo, hi = hole[0]
                        failures.append(
                            f'scripts/{fn}:{lineno} still names ${addr:04X}, '
                            f'inside the RETIRED harness block '
                            f'(${lo:04X}-${hi:04X}) -- '
                            f'these constants are hand-copied per script, so '
                            f'a relocation that misses one leaves that gate '
                            f'poking bytes the image now owns')

    built = os.path.join(ROOT, 'build', PT_HOLD_IMAGE)
    if not os.path.exists(built):
        failures.append(
            f'{PT_HOLD_IMAGE} is not built -- run `make play-image` '
            f'before this gate, which cannot bound an image it cannot '
            f'measure')
        return failures
    org = get_manifest_org(os.path.join(ROOT, PT_HOLD_ORG_MANIFEST))
    end = org + os.path.getsize(built)
    if end > low:
        lowest = [n for n, a in cells.items() if a == low][0]
        failures.append(
            f'{PT_HOLD_IMAGE} ends at ${end:04X}, at or past the harness '
            f'result block (${low:04X}-${high - 1:04X}, lowest cell '
            f'{lowest}) -- the image loads over its own verdict, so the '
            f'gates time out at the READY checkpoint or read blank '
            f'result cells instead of naming this')
    else:
        headroom = low - end
        print(f'[check-kernel-images] {PT_HOLD_IMAGE} ends ${end:04X}, '
              f'{len(cells)} harness cells at ${low:04X}-${high - 1:04X} '
              f'below ceiling ${ceiling:04X}: {headroom} B of headroom')
        # docs/KSEG.md, coordinator review 2026-09-27: a HARD floor, not
        # just a headroom report -- a ratchet like KNOWN_OVERRUN's, pinned
        # at the achieved headroom (round DOWN to a multiple of 128,
        # minimum 256) once the segment mechanism + /dev landed at exactly
        # 256 B. Future growth into this margin is a real regression this
        # gate must catch, same as any other ceiling in this file; future
        # SLACK (more headroom) is fine and simply raises the number the
        # next time someone measures it and updates the constant.
        if headroom < PT_HOLD_HEADROOM_FLOOR:
            failures.append(
                f'{PT_HOLD_IMAGE} headroom is {headroom} B, below the '
                f'pinned floor of {PT_HOLD_HEADROOM_FLOOR} B '
                f'(PT_HOLD_HEADROOM_FLOOR) -- docs/KSEG.md\'s segment '
                f'mechanism was measured at exactly 256 B of headroom on '
                f'2026-09-27; something has grown the flat image since. '
                f'Move more of procbye.s\'s cold paths into the segment, '
                f'or relocate the PT_HOLD-family cell block, rather than '
                f'lowering this floor.')
    return failures


# KSPACE2 (docs/KSPACE2.md, 2026-10-11): the 768 B RATCHET. The 256 B
# floor above stays the hard refusal for MAUXPLAY; this row is the wall
# the NEXT stream reads before it hits it. Every kernel .SYSTEM image
# must end at least this far below its ceiling (the io_buffer floor,
# PMLI_IBF_BASE; for MAUXPLAY the lowest harness result cell, which is
# lower). It was pinned when the tightest image, MAUXEXPR, stood 7 B
# under the ceiling and a 20-byte universal kernel change could not
# land. A stream that must spend this margin lowers it here, in the
# open, with the number it measured -- not by growing past it.
HEADROOM_RATCHET = 768


def ratchet_failures(rows, ratchet):
    """rows: [(image name, headroom B below its ceiling)].  Pure, so
    the self-test can feed it planted rows."""
    return [f'{name}: {room} B below its ceiling, under the {ratchet} B '
            f'headroom ratchet (HEADROOM_RATCHET) by {ratchet - room} B'
            for name, room in rows if room < ratchet]


def check_headroom_ratchet():
    """Every built kernel image keeps HEADROOM_RATCHET bytes of room;
    prints the tightest.  Missing builds are check_kernel_image_ceiling's
    to report (it already refuses them)."""
    failures = []
    ceiling = get_pmli_ibf_base()
    graph, _pt = cm.build_graph()
    images, _pb = derive_kernel_images(graph)
    play_low = None
    cells = [_first_match(os.path.join(ROOT, PT_HOLD_MANIFEST),
                          re.compile(EQU_HEX_TEMPLATE.format(name=n),
                                     re.IGNORECASE)) for n in PT_CELLS]
    cells = [c for c in cells if c is not None]
    if cells:
        play_low = min(cells)
    rows = []
    for manifest, targets in images.items():
        org = get_manifest_org(manifest)
        for target in sorted(targets):
            if org is None or not os.path.exists(target):
                continue
            name = os.path.basename(target)
            top = ceiling
            if name == PT_HOLD_IMAGE and play_low is not None:
                top = min(top, play_low)
            rows.append((name, top - (org + os.path.getsize(target))))
    failures += ratchet_failures(rows, HEADROOM_RATCHET)

    # Teeth: a planted image one byte under the ratchet MUST be refused
    # and one exactly at it MUST pass, or this gate stopped looking.
    planted = [('PLANTED_UNDER', HEADROOM_RATCHET - 1)]
    if not ratchet_failures(planted, HEADROOM_RATCHET):
        failures.append('ratchet self-test: an image 1 B under the '
                        'ratchet was NOT refused')
    if ratchet_failures([('PLANTED_AT', HEADROOM_RATCHET)],
                        HEADROOM_RATCHET):
        failures.append('ratchet self-test: an image exactly at the '
                        'ratchet was refused')
    if rows:
        tight = min(rows, key=lambda r: r[1])
        print(f'[check-kernel-images] headroom ratchet {HEADROOM_RATCHET} '
              f'B over {len(rows)} images: tightest is {tight[0]} at '
              f'{tight[1]} B below its ceiling')
    return failures


def run_all():
    """Run every check in this module, print detail, return the combined
    failure list -- the shape check_modules.py's other folded-in
    sections (check_equ_forward_refs, check_manifest_lists) use."""
    failures = []
    failures += check_kernel_image_ceiling()
    failures += check_pt_hold_headroom()
    failures += check_headroom_ratchet()

    graph, _put_targets = cm.build_graph()
    images, _process_bearing = derive_kernel_images(graph)
    failures += check_staleness(graph, images)
    failures += check_output_errors()
    return failures


def main():
    os.chdir(ROOT)
    if '--targets' in sys.argv[1:]:
        # `make preflight` builds exactly these before measuring them
        graph, _put_targets = cm.build_graph()
        images, _process_bearing = derive_kernel_images(graph)
        print(' '.join(sorted(cm.rel(t) for ts in images.values()
                              for t in ts)))
        return 0
    failures = run_all()
    if failures:
        print()
        for f in failures:
            print(f'[check-kernel-images] FAIL: {f}', file=sys.stderr)
        return 1
    print()
    print('[check-kernel-images] PASS: kernel .SYSTEM images stay within '
          'their recorded ceiling, no stale builds, no silent merlin32 '
          'errors')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
