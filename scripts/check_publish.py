#!/usr/bin/env python3
"""check-publish -- what ships to the public repo, and what does not.

The house Forgejo is LAN-only, so everything in the tree is readable
there. The PUBLIC face is a different surface: one squashed commit per
release tag on GitHub. Git history never ships, which is why commit
messages are not this gate's problem -- only file CONTENTS are.

Two things this gate exists to prevent, both of which a human reviewer
misses at this scale (2700+ tracked files):

1. **Internal material in a file that ships.** Not just the obvious
   process documents: the tell is usually a path, a LAN hostname, or a
   cross-reference to a file that was itself suppressed.

2. **Dangling cross-references.** This is the one that bites. Suppressing
   a document silently breaks every comment that cites it by name, and
   the project is dense with such citations -- 52 shipping files pointed
   at a single internal document before this gate was written. A public
   repo full of pointers to files nobody can see is worse than one that
   never mentioned them.

WHAT IS DELIBERATELY ALLOWED
----------------------------
`learning:01M0...` handles stay in shipping code. They are footnotes into
the project's own engineering notebook, they leak no content, and
wherever one appears the surrounding comment already states the substance
it cites. Stripping them would be a comment-only rewrite of the entire
codebase, which is a change class that has cost this project real
debugging rounds for no behavioural gain. HACKING.md explains them to a
stranger in one paragraph instead. If that decision is ever reversed, it
is a scripted scrub plus a full sweep, as its own stream.

EVIDENCE IS EXEMPT FROM THE MARKER RULES, ON PURPOSE
----------------------------------------------------
The site publishes measured numbers and every one of them cites a log
under evidence/. Those logs ship, because a claim whose provenance cannot
be checked is exactly what this project refuses to make. They also
contain the absolute paths and the LAN hostname of the machine that
produced them -- and they are NOT scrubbed, because editing a captured
log to look tidy destroys the only property that makes it evidence. The
disclosure (a home-directory layout, a LAN name that resolves for nobody
else) is accepted knowingly.

Re-checked 2026-11-02 against the agent-name ruling, by materialising
the public tree and grepping THAT rather than re-reading this comment.
8 of the 15 carry a marker. Every agent-name hit -- 13 lines across six
conformance logs -- is part of the SAME absolute build path, the
worktree the sweep ran in, so the sentence above already covers them
and there is no second category to rule on. The gate now COUNTS them in
its report: "ratchet: 0" read alone says no shipping file names an
agent, and six do, which is a thing a later reader would otherwise
infer wrongly from a zero.

Which evidence ships is DERIVED from site/facts.py rather than listed
here: a fact cites a path, so that path ships. A list would drift the
first time a fact moved.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: Whole trees that never ship.
SUPPRESS_DIRS = (
    'docs/rc-1-logs/',   #: release-qualification logs: 8.2 MB, box hostnames
    'metrics/',          #: capture telemetry for the engineering notebook
    'refs/',             #: a notebook snapshot
)

#: Individual files that never ship.
SUPPRESS_FILES = (
    '.mcp.json',               #: this machine's emulator paths
    'scratchpad_unused.log',   #: an accidental paste, local paths
    'AGENTS.md',
    'CLAUDE.md',               #: superseded publicly by HACKING.md
    'docs/PUBLISH-SCRUB.md',   #: the scrub's own record: it quotes
                               #: every string it removes, so a
                               #: published copy hands the reader
                               #: back what was scrubbed
    'CODEX_REVIEW.md',
    'CODEX_CODE_REVIEW.md',
    'CODEX_HANDOFF.md',
    'FABLE_REVIEW.md',
    'FABLE_HANDOFF.md',
    'STREET_LIBRARY_REVIEW.md',
    #: The rig cut itself: it names what is withheld and why, which is
    #: the one document that must not travel with the thing it withholds.
    'docs/PUBLISH-RIG-CUT.md',
)

#: THE THIRD CATEGORY: withheld as rig.
#:
#: These ship nowhere, and for a different reason from SUPPRESS_FILES.
#: A suppressed file is internal -- process notes, a review, this
#: machine's paths. A withheld file is the opposite: it is good work, and
#: it is the test rig that validates the kernel against an emulator.
#: The operator's ruling (docs/PUBLISH-RIG-CUT.md, 2026-10-30) is that
#: the engine-validation half of the rig stays in-house -- it is what
#: lets this project make new toys at pace -- while the conformance half
#: and every host-oracle gate ship, because those prove maux behaves
#: like Unix and a stranger can run them.
#:
#: PINNED BY NAME, exactly like the two leak sets above and for the same
#: reason: a count would pass when one driver is swapped for another. A
#: script that changes bucket has to change this list, in the commit that
#: moves it, or the gate says which one and why.
#:
#: FIVE files are NOT here that a bucket-by-name reading would put here.
#: Three are the same lesson -- withholding a gate's TARGET is not
#: withholding its FILE:
#:   scripts/mcp_drive.py     -- check-boot's driver, and 131 shipping
#:                               gates import it as a library;
#:   scripts/build_image.py   -- `make image` is the documented first
#:                               build step, and it is a 40-line
#:                               zero-fill packer;
#:   scripts/profile_f2.py    -- profile-nas is withheld, but shipping
#:                               profile_nas_hotspots.py imports this.
#: The gate asserts that closure directly (see check()): no file that
#: ships may import a module that does not.
#:
#: The other two are the lesson the rig cut was built on, and they were
#: in gates.mk for an afternoon before measurement moved them out:
#:   scripts/check_altzp.py   -- sounds like the deepest engine gate in
#:   scripts/check_lc.py         the tree, and both are STATIC LINTS:
#:                               they read src/**/*.s and inc/*.equ and
#:                               boot nothing. check-host-sweep is what
#:                               found them -- they came out of the
#:                               emulator-free set, which a gate that
#:                               boots a machine cannot do. A
#:                               contributor editing kernel source needs
#:                               them and can run them.
#: Read what a gate ASSERTS, not what it is called. That is the third
#: time this classification was wrong in the same direction.
WITHHELD_RIG = frozenset((
    'gates.mk',
    'scripts/build_catread_image.py',
    'scripts/build_devblk_image.py',
    'scripts/build_devfs_image.py',
    'scripts/build_fileprocess_image.py',
    'scripts/build_floppy_image.py',
    'scripts/build_mli_image.py',
    'scripts/build_mlival_oracle.py',
    'scripts/build_partition_image.py',
    'scripts/build_pipewrap_image.py',
    'scripts/build_profile_image.py',
    'scripts/build_proshim_image.py',
    'scripts/build_sticky_image.py',
    'scripts/build_ut_image.py',
    #: the Apple2TS boot gate (docs/SITE.md D4) and the jest spec it
    #: drives. The .test.ts is DATA the driver reads, not a
    #: $(SCRIPTS)/ invocation, so no rule finds it -- it is pinned by
    #: hand, which is exactly the gap the gates.mk check names.
    'scripts/apple2ts/maux_boot.test.ts',
    'scripts/check_apple2ts.py',
    'scripts/check_bankcopy.py',
    'scripts/check_bye.py',
    'scripts/check_catread.py',
    'scripts/check_devblk.py',
    'scripts/check_devpath.py',
    'scripts/check_dirtyram.py',
    'scripts/check_fileprocess.py',
    'scripts/check_floppy.py',
    'scripts/check_fork.py',
    'scripts/check_ibf_ceiling.py',
    'scripts/check_idle.py',
    'scripts/check_ildl.py',
    'scripts/check_intr_prompt.py',
    'scripts/check_issue.py',
    'scripts/check_kseg.py',
    'scripts/check_lazyinval.py',
    'scripts/check_lazyvc.py',
    'scripts/check_lc_prodos.py',
    'scripts/check_lcbank.py',
    'scripts/check_loop.py',
    'scripts/check_masked.py',
    'scripts/check_mli.py',
    'scripts/check_mlival.py',
    'scripts/check_oftbye.py',
    'scripts/check_partition.py',
    'scripts/check_pipewrap.py',
    'scripts/check_play80.py',
    'scripts/check_play80n.py',
    'scripts/check_probe.py',
    'scripts/check_process.py',
    'scripts/check_proshim.py',
    'scripts/check_rambye.py',
    'scripts/check_ramdis.py',
    'scripts/check_ramworks_reset.py',
    'scripts/check_reset.py',
    'scripts/check_sched.py',
    'scripts/check_ser.py',
    'scripts/check_shutdown.py',
    'scripts/check_sticky.py',
    'scripts/check_switch_writers.py',
    'scripts/check_syscall.py',
    'scripts/check_tenant.py',
    'scripts/check_tip.py',
    'scripts/check_tip_vim.py',
    'scripts/check_typeahead.py',
    'scripts/check_ultraterm.py',
    'scripts/check_ut_bold.py',
    'scripts/check_ut_render.py',
    'scripts/check_vc.py',
    'scripts/check_vt102.py',
    'scripts/check_wake.py',
    'scripts/diag_as_hang.py',
    'scripts/dirtyram_taint.py',
    'scripts/exloop_matrix.py',
    'scripts/exloop_trace.py',
    'scripts/experiment_writelanding.py',
    'scripts/kcold_gates.py',
    'scripts/kcold_image.py',
    'scripts/measure_case.py',
    'scripts/measure_loop.py',
    'scripts/measure_loop_common.py',
    'scripts/measure_loop_q1.py',
    'scripts/measure_loop_q1_ref.py',
    'scripts/measure_loop_q2.py',
    'scripts/measure_loop_q3.py',
    'scripts/measure_loop_q4.py',
    'scripts/measure_loop_s2.py',
    'scripts/measure_loop_stock.py',
    'scripts/measure_mli.py',
    'scripts/measure_orphan.py',
    'scripts/measure_parallel_rig.py',
    'scripts/measure_sdk_cycles.py',
    'scripts/measure_vroot.py',
    'scripts/measure_wake.py',
    'scripts/measure_x_cycles.py',
    'scripts/oappend_cycles.py',
    'scripts/pace1_probe.py',
    'scripts/probe_astext.py',
    'scripts/probe_mvdir.py',
    'scripts/probe_rmhang.py',
    'scripts/profile_as.py',
    'scripts/profile_kcold.py',
    'scripts/profile_lazyfree.py',
    'scripts/profile_ls_echo.py',
    'scripts/profile_ls_echo_warm.py',
    'scripts/profile_nulib2.py',
    'scripts/profile_putc_decompose.py',
    'scripts/profile_selfhost.py',
    'scripts/profile_ttywrite.py',
    'scripts/profile_turnaround.py',
    'scripts/profile_vi_repaint.py',
    'scripts/profile_zpage.py',
    'scripts/race_privtree.py',
    'scripts/race_symbols.py',
    'scripts/teeth_orphan.py',
    'scripts/teeth_sleep.py',
    'scripts/teeth_wait.py',
    'scripts/teeth_wake.py',
    'scripts/trace_interaction.py',
))

#: The citation rule does not apply to the rig, and this is what pays for
#: that. Suppressing an internal document silently breaks every comment
#: that names it, so check() fails a shipping file that cites a
#: suppressed one -- see the header. The rig cannot work that way: 184
#: shipping files name a withheld driver 346 times, across docs, source
#: comments and the site, and every one of those references is TRUE and
#: useful. A comment saying which gate measured a cycle count is worth
#: keeping even when the reader cannot run that gate.
#:
#: So the rig is exempt, on one condition: the public tree must SAY SO,
#: once, where a contributor will read it. That sentence is load-bearing
#: and therefore gated -- lose it and the exemption goes with it.
#: Internal engineering notes: a document whose subject is a past piece
#: of WORK rather than the system -- a task brief and its -NOTES record,
#: a review record, a measurement report, a planning queue, a decision
#: backlog. Operator ruling 2026-11-02: where a doc is not really useful
#: to a public contributor, WITHHOLD it rather than rewrite it.
#:
#: Withheld, not suppressed, and the distinction is the whole point: a
#: suppressed file may not be NAMED by anything that ships, and these are
#: named constantly -- a design doc cites the note that settled it, a
#: source comment cites the brief it was built from. Suppressing them
#: would have meant rewording about 160 references, docs/PLAN.md alone
#: being named by roughly 100 shipping files including src/bin/sh.s. So
#: they take the rig's treatment instead: withheld from the tree, free to
#: be cited, and the exemption paid for by one sentence a contributor
#: actually reads (NOTES_NOTE below).
WITHHELD_NOTES = frozenset((
    'docs/ARCH-REVIEW-MEMORY-CODEX.md',
    'docs/ARCH-REVIEW-MEMORY-CODEX3.md',
    'docs/ARCH-REVIEW-MEMORY-REDTEAM.md',
    'docs/ARCH-REVIEW-MEMORY.md',
    'docs/AS-DESIGN.md',
    'docs/AS-LINKER-SPIKE.md',
    'docs/AS-PLASMA.md',
    'docs/AS-PROFILE.md',
    'docs/AS-PUT.md',
    'docs/AS-STREAM.md',
    'docs/AWK-BUILD.md',
    'docs/AWK.md',
    'docs/B1-NOTES.md',
    'docs/B1.md',
    'docs/BADVOL-WEDGE.md',
    'docs/BENCH-PLAN.md',
    'docs/BYE-SLICE1-NOTES.md',
    'docs/BYE-SLICE1.md',
    'docs/CD.md',
    'docs/COMMONS-OWED.md',
    'docs/COMPLETISH.md',
    'docs/CONSOLE-LATENCY.md',
    'docs/CONSOLE-N8-ERASE.md',
    'docs/CONSOLE-OPT.md',
    'docs/CONSOLE-RUN-BATCH.md',
    'docs/COVER-OFF.md',
    'docs/CWD-BANK-BUG.md',
    'docs/DECISIONS-PENDING.md',
    'docs/DEMO-DDSHRINK-NOTES.md',
    'docs/DEMO-DDSHRINK.md',
    'docs/DEMO-FEDGREP-NOTES.md',
    'docs/DEMO-FEDGREP.md',
    'docs/DEMO-PHOSPHOR.md',
    'docs/DEMO-UT-NOTES.md',
    'docs/DEMO-UT.md',
    'docs/DEMO-VIBANG-NOTES.md',
    'docs/DEMO-VIBANG.md',
    'docs/DEMO-W17-NOTES.md',
    'docs/DEMOS-W1-NOTES.md',
    'docs/DEMOS-W1.md',
    'docs/DEMOS.md',
    'docs/DEPS-TIER-NOTES.md',
    'docs/DEPS-TIER.md',
    'docs/DEV-BLOCK-NOTES.md',
    'docs/DEVFS-NOTES.md',
    'docs/DU-DF-NOTES.md',
    'docs/DU-DF.md',
    'docs/DUPFD-1-NOTES.md',
    'docs/DUPFD-1.md',
    'docs/E0.md',
    'docs/E2E-COVERAGE.md',
    'docs/E2E.md',
    'docs/EDASM-SHIM.md',
    'docs/ENCODING-CENSUS-NOTES.md',
    'docs/EX-BADCMD-NOTES.md',
    'docs/EX-BADCMD.md',
    'docs/EX-REFACTOR-PLAN.md',
    'docs/EXAMPLES-NOTES.md',
    'docs/EXAMPLES.md',
    'docs/EXEC-SHEBANG-NOTES.md',
    'docs/EXEC-SHEBANG.md',
    'docs/FAT.md',
    'docs/FINISH.md',
    'docs/FLEET.md',
    'docs/FLOPPY-E2E-NOTES.md',
    'docs/FLOPPY-E2E.md',
    'docs/FULLDISK-NOTES.md',
    'docs/FULLDISK.md',
    'docs/GATE-RACE-1-NOTES.md',
    'docs/GATE-RACE-1.md',
    'docs/GLOB-VROOT-NOTES.md',
    'docs/GLOB-VROOT.md',
    'docs/GREP-JIT.md',
    'docs/HYG-1-NOTES.md',
    'docs/HYG-1.md',
    'docs/HYG-2-NOTES.md',
    'docs/HYG-2.md',
    'docs/HYG-3-NOTES.md',
    'docs/HYG-3.md',
    'docs/HYG-4-NOTES.md',
    'docs/HYG-4.md',
    'docs/IDE.md',
    'docs/KBRK-NOTES.md',
    'docs/KBRK.md',
    'docs/KFIX-NOTES.md',
    'docs/KFIX.md',
    'docs/KFIX10-NOTES.md',
    'docs/KFIX10.md',
    'docs/KFIX11-NOTES.md',
    'docs/KFIX11.md',
    'docs/KFIX12-NOTES.md',
    'docs/KFIX12.md',
    'docs/KFIX2-NOTES.md',
    'docs/KFIX2.md',
    'docs/KFIX3-NOTES.md',
    'docs/KFIX3.md',
    'docs/KFIX4-NOTES.md',
    'docs/KFIX4.md',
    'docs/KFIX5-NOTES.md',
    'docs/KFIX5.md',
    'docs/KFIX6-NOTES.md',
    'docs/KFIX6.md',
    'docs/KFIX7-NOTES.md',
    'docs/KFIX7.md',
    'docs/KFIX8-NOTES.md',
    'docs/KFIX8.md',
    'docs/KFIX9-NOTES.md',
    'docs/KFIX9.md',
    'docs/KGAPS-NOTES.md',
    'docs/KGAPS.md',
    'docs/KLEDGER-HOTCOLD.md',
    'docs/KLEDGER-NOTES.md',
    'docs/KLEDGER.md',
    'docs/KSEG-NOTES.md',
    'docs/KSPACE-NOTES.md',
    'docs/KSPACE.md',
    'docs/KSPACE2-NOTES.md',
    'docs/KSPACE2.md',
    'docs/LD-DESIGN.md',
    'docs/LD-UNIFY.md',
    'docs/LOOP-S0-NOTES.md',
    'docs/LOOP-S0.md',
    'docs/LOOP-S1-NOTES.md',
    'docs/LOOP-S1.md',
    'docs/LOOP-S2-NOTES.md',
    'docs/LOOP-S2.md',
    'docs/MAKE-FLUSH-NOTES.md',
    'docs/NAS-COMMISSIONING.md',
    'docs/NAS-LINE-DESIGN.md',
    'docs/NAS-MERLIN-PATH-COMPARISON.md',
    'docs/NAS-NATIVE-LOOP-EXPERIMENT.md',
    'docs/NAS-NATIVE-REPLACEMENT.md',
    'docs/NAS-PASS1-DESIGN.md',
    'docs/NAS-PASS2-DESIGN.md',
    'docs/NAS-PERFORMANCE-PROGRESS.md',
    'docs/NAS-PERFORMANCE.md',
    'docs/NAS-PROMOTION-PROFILE.md',
    'docs/NAS-REFACTOR-DESIGN.md',
    'docs/NUFX-LC-NOTES.md',
    'docs/NUFX-LC.md',
    'docs/NUFX-PIPE-NOTES.md',
    'docs/NUFX-SDK-NOTES.md',
    'docs/OAPPEND-1-NOTES.md',
    'docs/OAPPEND-1.md',
    'docs/OPEN-RO-2-NOTES.md',
    'docs/OPEN-RO-2.md',
    'docs/OPEN-RO-NOTES.md',
    'docs/OPEN-RO.md',
    'docs/OPEN-RW-1-NOTES.md',
    'docs/OPEN-RW-1.md',
    'docs/OPEN-RW-2-NOTES.md',
    'docs/OPEN-RW-2.md',
    'docs/ORACLE-COVERAGE.md',
    'docs/ORPHAN-1-NOTES.md',
    'docs/ORPHAN-1.md',
    'docs/PACE-1-NOTES.md',
    'docs/PACE-1.md',
    'docs/PERF-PLAN.md',
    'docs/PLAN-ARCHIVE.md',
    'docs/PLAN.md',
    'docs/PLASM-FIX-NOTES.md',
    'docs/POSIX-DIFFR-NOTES.md',
    'docs/POSIX-DIFFR.md',
    'docs/POSIX-HARNESS-NOTES.md',
    'docs/POSIX-HARNESS.md',
    'docs/POSIX-ODT-NOTES.md',
    'docs/POSIX-ODT.md',
    'docs/POSIX-PR-NOTES.md',
    'docs/POSIX-PR.md',
    'docs/POSIX-REGEXLINK-NOTES.md',
    'docs/POSIX-REGEXLINK.md',
    'docs/POSIX-SORTK-NOTES.md',
    'docs/POSIX-SORTK.md',
    'docs/PRODOS-CASE-NOTES.md',
    'docs/PRODOS-CASE.md',
    'docs/PRODOS-SHIM.md',
    'docs/PRODOS-SPIKE.md',
    'docs/PRODOS25-NOTES.md',
    'docs/PS-ARGS-NOTES.md',
    'docs/PS-ARGS.md',
    'docs/RC-1-EVIDENCE.md',
    'docs/RC-1-NOTES.md',
    'docs/RC-1.md',
    'docs/RECORDER-NOTES.md',
    'docs/RECORDER.md',
    'docs/RECURSIVE-MV.md',
    'docs/REGEX-BRE-INTERVALS.md',
    'docs/REGEX-FASTPATH-GROUP.md',
    'docs/REL-LIBA-SPIKE.md',
    'docs/RESET.md',
    'docs/RULINGS-1-NOTES.md',
    'docs/RULINGS-1.md',
    'docs/S9-PLAN.md',
    'docs/SED.md',
    'docs/SELFHOST-CONVERSION.md',
    'docs/SELFHOST.md',
    'docs/SER-1-NOTES.md',
    'docs/SER-1.md',
    'docs/SER-2-NOTES.md',
    'docs/SER-2.md',
    'docs/SH-ALIAS-NOTES.md',
    'docs/SH-ALIAS.md',
    'docs/SH-BG.md',
    'docs/SH-CAPACITY.md',
    'docs/SH-CASE.md',
    'docs/SH-CASE2-NOTES.md',
    'docs/SH-CASE2.md',
    'docs/SH-DEFECTS-0-NOTES.md',
    'docs/SH-DEFECTS-12-NOTES.md',
    'docs/SH-DEFECTS-13-NOTES.md',
    'docs/SH-DEFECTS-14-NOTES.md',
    'docs/SH-DEFECTS-15-NOTES.md',
    'docs/SH-DEFECTS-2026-10-20.md',
    'docs/SH-DEFECTS-6-NOTES.md',
    'docs/SH-DEFECTS-8-NOTES.md',
    'docs/SH-DESIGN.md',
    'docs/SH-DOTPATH.md',
    'docs/SH-EXECLOOP-NOTES.md',
    'docs/SH-EXECLOOP.md',
    'docs/SH-FD-NOTES.md',
    'docs/SH-FD.md',
    'docs/SH-FEATURES.md',
    'docs/SH-FOREIGN.md',
    'docs/SH-G21-NOTES.md',
    'docs/SH-G21.md',
    'docs/SH-MLQUOTE-NOTES.md',
    'docs/SH-MLQUOTE.md',
    'docs/SH-NLVAR-NOTES.md',
    'docs/SH-NLVAR.md',
    'docs/SH-PIPE-NOSPACE.md',
    'docs/SH-PREFIX-NOTES.md',
    'docs/SH-PREFIX.md',
    'docs/SH-ROOM-NOTES.md',
    'docs/SH-ROOM.md',
    'docs/SH-ROOM2-NOTES.md',
    'docs/SH-ROOM2.md',
    'docs/SH-SEQ-NOTES.md',
    'docs/SH-SEQ.md',
    'docs/SH-SUBSET.md',
    'docs/SH-SUBSHELL.md',
    'docs/SHELL-GAPS.md',
    'docs/SHELL-SPLIT.md',
    'docs/SITE-LANDING-QUEUE.md',
    'docs/SITE-PAGES-NOTES.md',
    'docs/SITE-PAGES.md',
    'docs/SITE.md',
    'docs/SITEGEN-NOTES.md',
    'docs/SITEGEN.md',
    'docs/SLEEP-1-NOTES.md',
    'docs/SLEEP-1.md',
    'docs/SPAWN-BANK7-CRASH.md',
    'docs/SPAWNFAIL-AUDIT.md',
    'docs/STICKY.md',
    'docs/SUBSHELL-HANDOFF.md',
    'docs/TAB-A2-NOTES.md',
    'docs/TAB-A2.md',
    'docs/TAB-A3-NOTES.md',
    'docs/TAB-A3.md',
    'docs/TAB-COMPLETION-CODEX.md',
    'docs/TAB-COMPLETION.md',
    'docs/TASKS.md',
    'docs/TTY-TYPEAHEAD-BELL-NOTES.md',
    'docs/TTY-TYPEAHEAD-BELL.md',
    'docs/ULTRATERM-VRAM-RESIDENT.md',
    'docs/UNPACK-E2E-NOTES.md',
    'docs/UNPACK-E2E.md',
    'docs/UT-CELL-NOTES.md',
    'docs/VI-ALTSCREEN.md',
    'docs/VI-BANG.md',
    'docs/VI-GAPS-2-NOTES.md',
    'docs/VI-GAPS-2.md',
    'docs/VI-GLASS-P-NOTES.md',
    'docs/VI-GLASS-P.md',
    'docs/VI-SHELLOUT-CRASH.md',
    'docs/VROOT-NOTES.md',
    'docs/WAIT-1-NOTES.md',
    'docs/WAIT-1.md',
    'docs/WAKE-1-NOTES.md',
    'docs/WAKE-1.md',
))

#: What the notes exemption costs, stated where a contributor reads it,
#: exactly as RIG_NOTE does for the gate drivers. Lose the sentence and
#: every citation of a withheld note becomes a silent dangling pointer.
NOTES_NOTE = 'not every document this tree cites is published'
NOTES_NOTE_IN = 'HACKING.md'

RIG_NOTE = 'not every gate in this tree has its driver published'
RIG_NOTE_IN = 'HACKING.md'

#: And the third of the family. 727 lines across 294 shipping files
#: cite a `learning:<ULID>` handle -- 139 of them source comments,
#: where the house rule is that a learning which shaped code is cited
#: beside it. The handles resolve against a collection kept outside
#: this repository, so to a public reader they look like dead
#: references. Operator ruling, 2026-11-02: they STAY, and one
#: sentence a contributor reads says what they are. The alternative
#: measured at 868 lines of hand-rewriting across 315 files, and it
#: would have destroyed the chain of custody that makes a hardware
#: claim auditable -- the handle is the only pointer from a line of
#: 6502 back to the evidence that settled it.
LEARNING_NOTE = 'not every source a claim cites is published'
LEARNING_NOTE_IN = 'HACKING.md'

#: docs/ SHIPS WHOLE (operator decision, 2026-10-29). The alternative was
#: suppressing the stream/process documents by filename shape, which
#: measured badly: 124 docs would go, and the corpus is cross-linked
#: densely enough that the 207 survivors cited them 822 times. A public
#: repo full of pointers to files nobody can see is worse than one that
#: publishes its engineering log. Classifying by CONTENT instead was
#: worse still -- 226 of 331 root docs carry process prose.
#:
#: So the log ships as it stands, process prose and all, and what gets
#: removed is only what a stranger cannot use or should not be handed:
#: see FORBIDDEN. Naming the engineering notebook is likewise accepted
#: (81 docs do); the commits already carry their own attribution, so
#: none of this is concealed by suppressing a word.

#: SHRINK-ONLY PINS, with named triggers. Two leaks cannot be fixed by
#: editing prose, because the honest replacement does not exist yet:
#:
#:   LAN hostname -- docs cite forgejo.cornflower.au for a2til,
#:   verilogapple and maux itself. a2til is mirrored publicly
#:   (github.com/emdeejay/a2til, and on PyPI), but maux has no public
#:   home yet and verilogapple is LAN-only by ruling. Rewriting these to
#:   GitHub URLs would invent links that 404, which is worse than a
#:   hostname a stranger can see is private.
#:   TRIGGER: creating the public maux repo, and deciding whether
#:   verilogapple gets a public home. Then this pin goes to 0.
#:
#:   local path -- three files, and each is a different thing:
#:   dependencies.lock.json records where an operator-supplied ROM was
#:   found (changing a verified lock needs its own verification);
#:   check_dependencies.py hardcodes a home directory as a FUNCTIONAL
#:   match prefix, where `~/` would not expand; PROJECT-STATE.md is the
#:   open TODO to remove that very prefix.
#:   TRIGGER: PROJECT-STATE.md's own item -- make the PLASMA and
#:   verilogapple paths overrideable.
#:
#: These are pins, not exemptions: a NEW file leaking either marker
#: pushes the count above its pin and this gate goes red.
#: The two leaks that DO ship, pinned BY NAME rather than by count. A
#: count-pin passes when one carrier is swapped for another, which is the
#: same silent-permission hazard as a ratchet sitting above its measured
#: value; naming them means the gate can say WHICH file is new. Both sets
#: shrink to empty on a named trigger: the hostname set when the public
#: repo exists and verilogapple's public status is decided, the local-path
#: set on docs/PROJECT-STATE.md's own TODO to make paths overrideable.
HOSTNAME_PIN = frozenset((
    'Makefile',
    'dependencies.lock.json',
    'docs/CONSOLE.md',
    'scripts/box_gate.sh',
    'scripts/box_provision.sh',
    'scripts/check_site.py',
))
LOCALPATH_PIN = frozenset((
    'dependencies.lock.json',
    'docs/PROJECT-STATE.md',
    'scripts/check_dependencies.py',
))
#: Files that name a coding agent or a model. The tree records WHO did
#: each piece of work, in task-note headers ("Engineer: ...") and in
#: provenance comments crediting a review finding ("(... 14)"), and that
#: is development process rather than anything a reader of the published
#: tree needs. Operator ruling 2026-11-02, taken while cutting 1.0: hold
#: the publish and scrub this first.
#:
#: THIS PIN MAY ONLY SHRINK. It is a ratchet, not an allowance: 200
#: files and 534 lines at the ruling, and the scrub drives it to zero.
#: A file not named here that acquires the vocabulary goes RED, which is
#: what stops the count growing while the scrub runs. Measured cost of
#: the last four: exactly 4 of the 61 matches under src/ are TRAILING
#: comments, which strip_comments.py does not blank, so they reach
#: /usr/src on the release disk -- changing them changes full.po and
#: stales every recorded film and lesson session. The other 57 are
#: comment-only lines, stripped before staging, and cost nothing.
#:
#: Not here, and not carriers: the six cited conformance logs (exempt
#: from the marker rules because site/facts.py cites them) and this
#: file, which names the pattern. The gate's own stale-pin rule
#: refused all seven when they were pinned, which is the rule working.
AGENT_PIN = frozenset((
))

PINS = {'LAN hostname': HOSTNAME_PIN, 'local path': LOCALPATH_PIN,
        'agent name': AGENT_PIN}

#: Two build files name a tool DIRECTORY, not who did the work:
#: `.gitignore` ignores the editor's worktree folder and `box_gate.sh`
#: excludes it from the rsync to the gate box. Both are functional --
#: delete them and a stray folder gets committed, or copied to the box
#: and gated. The provenance ratchet above is about the tree RECORDING
#: who did each piece of work, which these do not, so operator ruling
#: 2026-11-02 declares them exempt and keeps them OUT of that ratchet:
#: the ratchet reaches zero and stays a ratchet, instead of resting
#: forever at two with a footnote.
#:
#: Narrow, and DERIVED rather than taken on trust. The exemption covers
#: exactly the directory token below: every agent-name match in the file
#: must disappear once that token is removed, or the file fails like any
#: other. So a provenance line added to `.gitignore` later is still
#: caught, which a bare name list would not do -- the hazard being that
#: a pin paired with no derived rule reads green for whatever else the
#: file grows. Trigger to remove: the folder is named by the editor, so
#: this goes when the tree stops carrying an ignore rule for it.
TOOLDIR_TOKEN = '.claude/'
TOOLDIR_EXEMPT = frozenset((
    '.gitignore',
    'scripts/box_gate.sh',
))

#: Markers that must not appear in a file that ships. Each is a thing a
#: stranger either cannot use or should not be handed.
FORBIDDEN = (
    ('local path',    re.compile(r'/Users/mdj')),
    ('LAN hostname',  re.compile(r'cornflower\.au')),
    ('internal name', re.compile(r'maux-1c')),
    ('agent name',    re.compile(
        r'\b(Claude|Codex|Sonnet|Opus|Fable|subagent|GPT-?\d)\b',
        re.I)),
)

#: Binaries that ship must be DOCUMENTED -- the licensing posture is
#: "ship Apple II-era software, with its provenance recorded", and the
#: second half is the part that gets forgotten. The house already does
#: this well (fixtures/PROVENANCE.md records each archive's mirror,
#: original filename, size and sha256; fixtures/partition/PROVENANCE.md
#: and pinned/README.md do the same), so the rule is derived from that
#: practice rather than duplicating a list here that would drift: a
#: shipping binary must be named by some shipping .md file. A new blob
#: nobody wrote up fails this gate.
#: filled per run by check(); see the pins above
PINNED = {'LAN hostname': [], 'local path': [], 'agent name': []}

BINARY_RE = re.compile(r'\.(shk|obj|bin|rom|jed|po|dsk|2mg)$', re.I)

#: A learning handle: the literal prefix plus a Crockford ULID. Narrow
#: on purpose -- it must not match the word "learning" in prose, or the
#: count it drives stops meaning anything.
HANDLE_RE = re.compile(r'\blearning:[0-9A-HJKMNP-TV-Z]{26}\b')

#: The agent-name matcher, by name, so the tool-directory exemption's
#: self-test can plant a provenance line and require it to be caught.
AGENT_RE = dict((w, rx) for w, rx in FORBIDDEN)['agent name']

def tracked():
    """The tracked set, from git. There is deliberately no fallback.

    This gate decides what SHIPS, and "what ships" is exactly the tracked
    set -- which only git knows. A filesystem walk is not a substitute: it
    cannot tell a tracked file from a build artifact, so it measures a
    different and larger population and the pins then mean nothing.

    An earlier version did fall back to a walk, on the premise that "the
    box rsyncs without .git". That premise was wrong and it cost a red:
    the box tree carries a .git POINTER FILE naming the Mac worktree
    (/Users/mdj/src/maux/.git/worktrees/...), so git there fails, the walk
    ran, it counted 2918 files against the Mac's 2718, and the pointer
    file's own contents registered as a local-path leak. Hence: no
    fallback, and the gate is excluded from the box sweep (see the
    filter-out in Makefile's CHECK_BOX_TARGETS). It already runs on the
    Mac in `make preflight`, which box_gate.sh invokes before it syncs.
    """
    out = subprocess.run(['git', 'ls-files'], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode:
        return None
    return sorted(out.stdout.split('\n')[:-1] if out.stdout else [])


def cited_evidence():
    """evidence/ paths named by site/facts.py -- these ship."""
    try:
        with open(os.path.join(ROOT, 'site/facts.py'), encoding='ascii',
                  errors='replace') as fh:
            src = fh.read()
    except OSError:
        return set()
    cited = {m.rstrip('/') for m in
             re.findall(r'evidence/[A-Za-z0-9._/-]+', src)}
    # An evidence bundle is a unit: its README cites its sibling logs, so
    # shipping only the three files a fact names would publish a README
    # pointing at logs nobody can see. Cite one, ship the directory.
    return cited | {os.path.dirname(c) for c in cited
                    if os.path.dirname(c) != 'evidence'}


def suppressed(rel, keep_evidence):
    if rel in WITHHELD_RIG or rel in WITHHELD_NOTES:
        return True
    if rel.startswith(SUPPRESS_DIRS):
        return True
    if rel in SUPPRESS_FILES:
        return True
    if rel.startswith('evidence/'):
        # ships only if a fact cites it, or it is inside a cited directory
        return not any(rel == k or rel.startswith(k + '/')
                       for k in keep_evidence)
    return False


def classify(paths):
    """ships / suppressed-as-internal / withheld-as-rig.

    The third bucket is split out rather than folded into the second
    because the two get DIFFERENT treatment downstream: an internal file
    may not be named by anything that ships, and a rig file may (see
    RIG_NOTE).
    """
    keep = cited_evidence()
    ship, drop, rig, notes = [], [], [], []
    for rel in paths:
        if rel in WITHHELD_RIG:
            rig.append(rel)
        elif rel in WITHHELD_NOTES:
            # A FOURTH bucket for the same reason the third exists: the
            # citation rule scans `drop`, and these may be cited.
            notes.append(rel)
        elif suppressed(rel, keep):
            drop.append(rel)
        else:
            ship.append(rel)
    return ship, drop, rig, notes


def read(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding='ascii',
                  errors='replace') as fh:
            return fh.read()
    except (OSError, UnicodeError):
        return ''


def check(paths):
    fails = []
    for v in PINNED.values():
        del v[:]
    ship, drop, rig, notes = classify(paths)
    # Cite-by-basename only works for a basename that is UNIQUE to the
    # suppressed set. README.md is dropped under an uncited evidence/
    # directory AND shipped at the root, so matching on the bare name
    # would report the root README as a dangling reference to itself.
    # Basename matching is reserved for the suppressed ROOT documents,
    # whose names are unambiguous. Everything else is matched as a full
    # path with a path-like left boundary.
    def cites(body, token):
        return re.search(r'(?<![A-Za-z0-9_/+.:-])' + re.escape(token), body)

    # Deliberately NOT including the rig here: see RIG_NOTE. The
    # exemption is paid for by the note being present, asserted below.
    dropped_paths = [d for d in drop
                     if not d.startswith(('docs/rc-1-logs/', 'evidence/'))]

    # What the rig exemption costs, stated once where a contributor
    # reads it. If that sentence goes, so does the exemption: every
    # citation of a withheld driver becomes a silent dangling pointer
    # again, which is the thing this gate was written to stop.
    # Normalised before comparing: the sentence lives in prose, so it
    # wraps across lines and carries markdown emphasis. Gating the exact
    # bytes would make a reflow a gate failure, and a gate that fires on
    # a reflow is a gate somebody deletes.
    def says(rel, sentence):
        flat = ' '.join(read(rel).replace('*', '').replace('`', '').split())
        return sentence.lower() in flat.lower()

    # A gate defined in gates.mk is withheld, so its DRIVER has to be
    # withheld too. Otherwise the public tree ships a script with no
    # target that can run it, and the rig cut leaks the very thing it
    # exists to keep. Nothing enforced this when gates.mk was written:
    # WITHHELD_RIG is pinned BY NAME, which is what makes a bucket
    # change a gate failure -- but a gate added to gates.mk LATER takes
    # its driver straight into the shipping set, silently. Found
    # 2026-10-30, the same day, by a new gate doing exactly that.
    # Scope note: a script named by BOTH files is a shared tool and
    # ships, which is why this subtracts the Makefile's set rather than
    # testing gates.mk alone.
    def scripts_named(rel):
        return set(re.findall(r'\$\(SCRIPTS\)/([A-Za-z0-9_./-]+)', read(rel)))

    # Narrower than it first looks, and deliberately. "Invoked only by a
    # gates.mk target" does NOT by itself mean rig: most of these files
    # are also LIBRARY modules that shipping scripts import (check_devfs
    # has twenty importers). Withholding one of those would break the
    # public tree -- the same "a shipping file may not import a withheld
    # module" rule asserted just above, from the other side. So a
    # candidate is a rig driver only if nothing that ships imports it.
    # The first cut of this check named ten such modules and was wrong
    # about all ten.
    shipped_imports = set()
    for rel in ship:
        if rel.endswith('.py'):
            for m in re.findall(r'^\s*(?:from|import)\s+([A-Za-z_][\w.]*)',
                                read(rel), re.M):
                shipped_imports.add(m.split('.')[0])

    if 'gates.mk' in paths:
        for name in sorted(scripts_named('gates.mk') - scripts_named('Makefile')):
            rel = 'scripts/' + name
            if (rel in paths and rel not in WITHHELD_RIG
                    and os.path.basename(rel)[:-3] not in shipped_imports):
                fails.append(f'FAIL: {rel} is invoked only by a gates.mk '
                             f'target and nothing that ships imports it, so '
                             f'it is a rig driver -- but it is not in '
                             f'WITHHELD_RIG, so it would SHIP with no target '
                             f'able to run it. Pin it by name, and check '
                             f'whether it reads data files of its own that '
                             f'need pinning too')

    if notes and not says(NOTES_NOTE_IN, NOTES_NOTE):
        fails.append(f'{NOTES_NOTE_IN} no longer says {NOTES_NOTE!r} -- '
                     f'that sentence is what lets {len(notes)} withheld '
                     f'engineering note(s) be NAMED by files that ship. '
                     f'Restore it, or start declaring every citation')

    handles = [r for r in ship if HANDLE_RE.search(read(r) or '')]
    if handles and not says(LEARNING_NOTE_IN, LEARNING_NOTE):
        fails.append(f'{LEARNING_NOTE_IN} no longer says '
                     f'{LEARNING_NOTE!r} -- that sentence is what makes '
                     f'the learning handles in {len(handles)} shipping '
                     f'file(s) a reference rather than a dead link. '
                     f'Restore it, or start removing the handles')

    if rig and not says(RIG_NOTE_IN, RIG_NOTE):
        fails.append(f'{RIG_NOTE_IN} no longer says {RIG_NOTE!r} -- that '
                     f'sentence is what lets {len(rig)} withheld rig '
                     f'file(s) be NAMED by files that ship. Restore it, '
                     f'or start declaring all 346 citations')

    # A file that ships may NAME a withheld script (above). It may not
    # IMPORT one: a dangling reference in a comment costs a reader a
    # search, a dangling import costs them an ImportError. Measured once
    # and it was real -- profile_nas_hotspots.py imports profile_f2,
    # which is why profile_f2 ships.
    rigmod = {os.path.basename(p)[:-3] for p in rig if p.endswith('.py')}
    for rel in ship:
        if not rel.endswith('.py'):
            continue
        for m in re.findall(r'^\s*(?:from|import)\s+([A-Za-z_][\w.]*)',
                            read(rel), re.M):
            if m.split('.')[0] in rigmod:
                fails.append(f'{rel} ships and imports {m}, which does '
                             f'not -- that is an ImportError in the '
                             f'public tree, not a dangling comment')
    documented = set()
    for rel in ship:
        if rel.endswith('.md'):
            body = read(rel)
            for s2 in ship:
                b = os.path.basename(s2)
                if BINARY_RE.search(b) and b in body:
                    documented.add(b)
    # a suppressed tree is cited by its path, not its basename
    dropped_dirs = tuple(d for d in SUPPRESS_DIRS)

    for rel in ship:
        if BINARY_RE.search(rel):
            if os.path.basename(rel) not in documented:
                fails.append(f'{rel}: a binary that ships, named by no '
                             f'shipping .md -- record its provenance')
            continue
        # This gate's own source must be free to NAME what it forbids:
        # the header explains each marker and the self-test plants them.
        if rel == 'scripts/check_publish.py':
            continue
        # evidence is exempt from the marker rules (see the header)
        exempt = rel.startswith('evidence/')
        body = read(rel)
        if not body:
            continue
        if not exempt:
            for what, rx in FORBIDDEN:
                hay = body
                if what == 'agent name' and rel in TOOLDIR_EXEMPT:
                    # The declared exemption, applied by SUBTRACTION:
                    # take the tool-directory token out and require what
                    # is left to be clean. Nothing else in the file is
                    # covered.
                    hay = body.replace(TOOLDIR_TOKEN, '')
                if rx.search(hay):
                    if what in PINNED:
                        PINNED[what].append(rel)
                    else:
                        fails.append(f'{rel}: {what} in a file that ships')
        # A document may DECLARE that something it cites is not published.
        # The point of this check is to stop SILENT dangling pointers; a
        # stated one tells the reader something true, and keeping the
        # path is better than deleting the fact that the logs exist.
        declared = tuple(re.findall(r'NOT PUBLISHED: ([^\s)`]+)', body))
        for name in SUPPRESS_FILES:
            if cites(body, name) and not name.startswith(declared or ('\0',)):
                fails.append(f'{rel}: cites {name}, which does not ship '
                             f'-- a dangling reference in the public repo')
        for d in dropped_paths + list(dropped_dirs):
            if cites(body, d) and not d.startswith(declared or ('\0',)):
                fails.append(f'{rel}: cites {d}, which does not ship')
    for what, pin in PINS.items():
        got = set(PINNED[what])
        added = sorted(got - pin)
        gone = sorted(pin - got)
        if added:
            fails.append(f'{what}: {len(added)} file(s) newly carry it: '
                         f'{added} -- either stop naming it there, or add '
                         f'the file to this gate\'s pin with a reason')
        if gone:
            fails.append(f'{what}: {len(gone)} pinned file(s) no longer '
                         f'carry it: {gone} -- drop them from the pin in '
                         f'this commit, the set only shrinks')

    # One complaint per (file, target), which is what this always meant
    # to do: a suppressed root document is both a SUPPRESS_FILES name
    # and a dropped path, and the two messages differ by a trailing
    # clause, so deduping on the whole string printed it twice.
    seen, uniq = set(), []
    for f in fails:
        key = re.sub(r' -- .*$', '', f)
        if key not in seen:
            seen.add(key)
            uniq.append(f)
    return uniq, ship, drop, rig, notes


def self_test(paths):
    """Plant each defect class and require this gate to see it."""
    out = []
    ship, drop, rig, notes = classify(paths)

    # A rig pin naming a file that no longer exists can never fail, the
    # same hazard as a stale leak pin -- and here it is worse, because
    # the name going stale is how a renamed driver quietly starts
    # shipping.
    for rel in sorted(WITHHELD_RIG):
        if rel not in paths:
            out.append(f'self-test: the rig set names {rel!r}, which is '
                       f'not a tracked file -- a stale pin reads green '
                       f'forever, and a renamed driver would ship')
    if set(WITHHELD_RIG) & set(ship):
        out.append(f'self-test: {sorted(set(WITHHELD_RIG) & set(ship))} is '
                   f'in the rig set AND in the ship list')
    if WITHHELD_RIG and not rig:
        out.append('self-test: the rig set matches NOTHING in the tree')
    # The MATCHER's teeth, not the note's -- whether HACKING.md still
    # carries the sentence is check()'s complaint, where the message can
    # say what the exemption costs. Here: prove the matcher tolerates a
    # reflow (or a routine rewrap turns the gate red) and still refuses
    # text with the promise taken out of it (or it passes forever).
    flat = RIG_NOTE.replace(' ', '\n  #: ')
    def norm(t):
        return ' '.join(t.replace('*', '').replace('`', '').replace('#:', '')
                        .split()).lower()
    if RIG_NOTE.lower() not in norm('**' + flat + '**'):
        out.append('self-test: the rig-note matcher rejects the sentence '
                   'merely reflowed and emphasised -- a rewrap would go red')
    if RIG_NOTE.lower() in norm(flat.replace('published', 'withheld')):
        out.append('self-test: the rig-note matcher accepted text with the '
                   'promise taken out -- it would pass with the note gone')

    # The notes category gets the rig's rows, for the rig's reasons: a
    # pin naming a file that no longer exists reads green forever, and a
    # file in both buckets would be published and withheld at once.
    for rel in sorted(WITHHELD_NOTES):
        if rel not in paths:
            out.append(f'self-test: the notes set names {rel!r}, which is '
                       f'not a tracked file -- a stale pin reads green '
                       f'forever, and a renamed note would ship')
    both = sorted(set(WITHHELD_NOTES) & set(WITHHELD_RIG))
    if both:
        out.append(f'self-test: {both} is in BOTH the notes set and the '
                   f'rig set -- one file, two exemptions, and the counts '
                   f'in the report stop adding up')
    if set(WITHHELD_NOTES) & set(ship):
        out.append(f'self-test: '
                   f'{sorted(set(WITHHELD_NOTES) & set(ship))} is in the '
                   f'notes set AND in the ship list')
    if WITHHELD_NOTES and not notes:
        out.append('self-test: the notes set matches NOTHING in the tree')
    # The already-public detector's teeth, from the other side: in a
    # REAL checkout every withheld path is tracked, so a detector that
    # fired here would turn this gate into a no-op without saying so.
    # This row is what stops that -- it is the failure mode of the fix,
    # not of the thing being fixed.
    decl = set(WITHHELD_RIG) | set(WITHHELD_NOTES)
    miss = sorted(decl - set(paths))
    if decl and len(miss) > len(decl) // 2:
        out.append(f'self-test: {len(miss)} of {len(decl)} withheld '
                   f'paths are not tracked, so the already-public '
                   f'detector is close to firing in what should be a '
                   f'real checkout -- e.g. {miss[:4]}')
    lflat = LEARNING_NOTE.replace(' ', '\n  #: ')
    if LEARNING_NOTE.lower() not in norm('**' + lflat + '**'):
        out.append('self-test: the learning-note matcher rejects the '
                   'sentence merely reflowed and emphasised -- a rewrap '
                   'would go red')
    if LEARNING_NOTE.lower() in norm(lflat.replace('published', 'withheld')):
        out.append('self-test: the learning-note matcher accepted text '
                   'with the promise taken out -- it would pass with the '
                   'note gone')
    for rel in sorted(TOOLDIR_EXEMPT):
        if rel not in paths:
            out.append(f'self-test: the tool-directory exemption names '
                       f'{rel!r}, which is not a tracked file -- a stale '
                       f'exemption reads green forever')
            continue
        body = read(rel) or ''
        if TOOLDIR_TOKEN not in body:
            out.append(f'self-test: {rel} no longer contains '
                       f'{TOOLDIR_TOKEN!r} -- drop it from the exemption, '
                       f'which only shrinks')
        planted = body + '\n# Engineer: Codex, branch x\n'
        if not AGENT_RE.search(planted.replace(TOOLDIR_TOKEN, '')):
            out.append(f'self-test: the tool-directory exemption swallows '
                       f'a planted provenance line in {rel} -- it is '
                       f'meant to cover the directory token alone')
    if not HANDLE_RE.search('learning:01M0KMQB3GE9W15R1G2G7AGFT0'):
        out.append('self-test: the handle pattern does not match a real '
                   'handle -- the count it drives would read zero')
    if HANDLE_RE.search('a learning: about the console') or \
       HANDLE_RE.search('learning:01M0KMQB3GE9W15R1G2G7AGFT'):
        out.append('self-test: the handle pattern matches prose or a '
                   'short ULID -- its count would be noise')

    # --list is what `make public-tree` and the release packager
    # SUBTRACT, so every bucket the report counts must also be a bucket
    # the list names. This row is the one that was missing: it compares
    # the counted buckets against the complement of the ship list, so a
    # bucket wired into classify() but not into the report (or the
    # reverse) is a failure here rather than a quiet leak at publish
    # time.
    counted = set(drop) | set(rig) | set(notes)
    missing = sorted(set(paths) - set(ship) - counted)
    extra = sorted(counted & set(ship))
    if missing:
        out.append(f'self-test: {len(missing)} path(s) neither ship nor '
                   f'appear in any counted bucket, e.g. {missing[:5]} -- '
                   f'the report and the machine list disagree')
    if extra:
        out.append(f'self-test: {extra[:5]} is counted as withheld AND '
                   f'in the ship list')
    nflat = NOTES_NOTE.replace(' ', '\n  #: ')
    if NOTES_NOTE.lower() not in norm('**' + nflat + '**'):
        out.append('self-test: the notes-note matcher rejects the sentence '
                   'merely reflowed and emphasised -- a rewrap would go red')
    if NOTES_NOTE.lower() in norm(nflat.replace('published', 'withheld')):
        out.append('self-test: the notes-note matcher accepted text with '
                   'the promise taken out -- it would pass with the note '
                   'gone')

    if not drop:
        out.append('self-test: the suppress rules match NOTHING -- they '
                   'have gone stale against the tree')
    for rule in SUPPRESS_DIRS:
        if not any(d.startswith(rule) for d in drop):
            out.append(f'self-test: suppress rule {rule!r} matches no '
                       f'file; a stale rule reads green forever')

    # A pin naming a file that no longer exists is a pin that can never
    # fail, and it masks a new carrier arriving in its place.
    for what, pin in PINS.items():
        for rel in sorted(pin):
            if rel not in paths:
                out.append(f'self-test: the {what} pin names {rel!r}, '
                           f'which is not a tracked file -- a stale pin '
                           f'reads green forever')

    # planted defects, in memory: each must be caught
    probes = (
        ('local path', '/Users/mdj/src/maux'),
        ('LAN hostname', 'verilogapple.cornflower.au'),
        ('internal name', 'maux-1c'),
    )
    for what, text in probes:
        if not any(rx.search(text) for _, rx in FORBIDDEN):
            out.append(f'self-test: a planted {what} ({text!r}) was NOT '
                       f'caught by FORBIDDEN')
    if any(rx.search('learning:01M044DYE1X50A34ZKG3FRRRQA')
           for _, rx in FORBIDDEN):
        out.append('self-test: a learning handle was refused, but handles '
                   'are deliberately allowed to ship')
    return out


def main():
    paths = tracked()
    if paths is None:
        print('[check-publish] error: `git ls-files` failed in '
              f'{ROOT} -- this gate\'s oracle is the git index and it has '
              'no fallback (see tracked()). Run it from a real checkout; '
              'it is excluded from the box sweep for this reason.',
              file=sys.stderr)
        return 2
    if not paths:
        print('error: no tracked files found', file=sys.stderr)
        return 2

    # --list is a MACHINE mode: stdout must be nothing but paths, because
    # `make public-tree` deletes what it prints. The self-test banner used
    # to go to stdout unconditionally and landed in that list as a
    # 1042nd "path" -- harmless to rm -f, wrong in every count, and
    # poison for any other consumer. Human output goes to stderr here.
    listing = '--list' in sys.argv or '--list-rig' in sys.argv
    say = (lambda m: print(m, file=sys.stderr)) if listing else print

    # ALREADY-PUBLIC TREES PASS, and they have to.
    #
    # Every pin and every suppress rule in this file names a path that
    # the public tree does not contain -- that is the whole point of
    # them -- so the self-test's stale-pin rules, which are right and
    # load-bearing in a real checkout, fire about 1300 times in a
    # published clone. That made `make check-all-host` RED on a fresh
    # clone of the published repo: the first command HACKING.md tells a
    # contributor to run, failing on the one gate whose question was
    # already answered upstream. Found 2026-11-02 by `make public-tree`,
    # `git init`, and running the sweep there; it is invisible from
    # in-house, where every pinned file exists.
    #
    # The detector is DERIVED and cannot be set by hand: the two
    # withheld sets name 393 paths that a real checkout tracks in full
    # and a published tree tracks none of. Zero of 393 is not a
    # middle case, and the self-test below proves the detector does
    # not misfire where it matters -- in this checkout, where all 393
    # are present.
    declared = set(WITHHELD_RIG) | set(WITHHELD_NOTES)
    present = len(declared & set(paths))
    if declared and present == 0:
        say(f'[check-publish] this tree is ALREADY PUBLIC: none of the '
            f'{len(declared)} withheld paths is tracked here, so the '
            f'classification happened upstream and there is nothing '
            f'left for this gate to decide. PASS by construction. The '
            f'gate that matters for this tree ran before it was '
            f'published.')
        return 0

    fails = self_test(paths)
    if fails:
        for f in fails:
            say(f'[check-publish] {f}')
        return 1
    say('[check-publish] self-test: planted markers caught, suppress '
        'rules live, every pinned carrier still tracked, handles still '
        'allowed')

    fails, ship, drop, rig, notes = check(paths)
    if '--list' in sys.argv:
        # DERIVED from the ship list, not assembled from the buckets.
        # It used to print `drop + rig`, which was every bucket there
        # was on the day it was written -- and then WITHHELD_NOTES
        # landed EMPTY, so for as long as it stayed empty the omission
        # could not show up in any count. The first 278 notes put into
        # it would have shipped in `make public-tree` and in the
        # release tarball, both of which subtract exactly what this
        # prints. Deriving it means a bucket added later is covered the
        # day it is added, with nothing to remember.
        for d in sorted(set(paths) - set(ship)):
            print(d)
        return 0
    if '--list-rig' in sys.argv:
        for d in rig:
            print(d)
        return 0

    print(f'[check-publish] {len(ship)} file(s) ship, {len(drop)} '
          f'suppressed as internal, {len(rig)} withheld as rig, of '
          f'{len(paths)} tracked')
    print(f'[check-publish] rig: {len(rig)} file(s) pinned BY NAME, '
          f'exempt from the citation rule because {RIG_NOTE_IN} says so '
          f'-- and no file that ships imports one')
    ev = sorted(p for p in ship if p.startswith('evidence/'))
    # COUNT what the exemption carries, do not just name it. "ratchet:
    # 0" read on its own says no shipping file names an agent, and six
    # do -- inside this exemption, every one of them as part of the
    # same absolute build path the header already accepts knowingly.
    # That is consistent, not an omission; it is also exactly the kind
    # of thing a later reader infers wrongly from a zero. So the gate
    # says the number out loud rather than leaving it to be rediscovered
    # by materialising the tree and grepping it, which is how it was
    # found.
    ev_carry = sorted(r for r in ev for _w, rx in FORBIDDEN
                      if rx.search(read(r) or ''))
    print(f'[check-publish] evidence: {len(ev)} file(s) ship because '
          f'site/facts.py cites them (exempt from the marker rules, '
          f'never scrubbed -- {len(set(ev_carry))} of them DO carry a '
          f'marker, accepted knowingly, see this file\'s header)')
    nbin = len([p for p in ship if BINARY_RE.search(p)])
    # Enumerated, not spelled out, so a set added later cannot be
    # carried silently: the agent-name ratchet was invisible in this
    # line for exactly as long as the line named its sets by hand.
    pinned = ', '.join(
        f'{len(PINNED[what])} {what} (pin {len(PINS[what])})'
        for what in sorted(PINNED))
    print(f'[check-publish] pinned markers: {pinned} -- each pinned BY '
          f'NAME, every set with a named trigger in this file')
    print(f'[check-publish] agent-name ratchet: '
          f'{len(PINNED["agent name"])} file(s) still name a coding agent '
          f'or model; the pin ({len(AGENT_PIN)}) may only SHRINK, and the '
          f'publish is held until it is zero')
    print(f'[check-publish] binaries shipping, each named by a shipping '
          f'.md: {nbin}')

    for f in fails:
        print(f'[check-publish] FAIL: {f}')
    if fails:
        print(f'[check-publish] {len(fails)} problem(s). Either the file '
              f'should not ship, or what it names should.')
        return 1
    print('[check-publish] PASS: nothing that ships names an internal '
          'file or imports a withheld one, no internal name reaches the '
          'public tree, and the four pinned sets -- two leaks, the '
          'agent-name ratchet and the rig -- are exactly as pinned, no '
          'file added, none gone stale')
    return 0


if __name__ == '__main__':
    sys.exit(main())
