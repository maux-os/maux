# maux -- toolchain + test-rig bootstrap (task #1)
#
# Toolchain: merlin32 (v1.1.10 brew; ~/src/malisp's Makefile is the
# reference pipeline this one follows -- see docs/TOOLCHAIN.md).
#
# Build artifacts:
#   build/bootblock.bin   raw 512-byte assembled boot block
#   build/maux.po         raw SmartPort block image, block 0 = bootblock,
#                          rest zero-filled (disk-image strategy stage 0,
#                          docs/TASKS.md #1)
#
# Rig: verilogapple headless MCP (fast + cycle-accurate rtl backends).
# `make check-boot` is the HARD GATE from the task contract -- both
# backends must show "MAUX ALIVE" via screen_text.

MERLIN32       ?= merlin32
SRC            := src
BUILD          := build
SCRIPTS        := scripts
INC            := inc
DEPS_ROOT      ?= $(CURDIR)/.deps
-include $(DEPS_ROOT)/dependencies.mk
# The dependency tier this tree was provisioned for (docs/DEPS-TIER.md).
# dependencies.mk sets it only for a build-tier bootstrap; absent means
# the test tier, which is every tree that predates the tiers.
MAUX_TIER      ?= test
export MAUX_TIER
A2TIL          ?= $(HOME)/src/a2til
MANDOC         ?= mandoc
export A2TIL
export MANDOC

# inc/memmap.equ split (2026-08-20, docs/SELFHOST-CONVERSION.md
# phase 1): the old 35888B monolith was one file every manifest's Make
# dependency list named; it is now seven per-concern includes (see
# docs/MEMMAP.md's header note for the reference-set analysis behind the
# grouping). Dependency lists below use this whole-set variable rather
# than naming only the subset a given manifest PUTs -- Make prerequisites
# are conservative-safe to over-list (an unused split file's edit just
# triggers a harmless extra rebuild), and the alternative (one bespoke
# subset per target) would silently drift the way KERNEL_PROC_MODS's own
# comment already warns against for kernel modules.
MEMMAP_ALL     := $(INC)/mm.procbank.equ \
                  $(INC)/mm.procbnk2.equ \
                  $(INC)/mm.hw.equ \
                  $(INC)/mm.mli.equ \
                  $(INC)/mm.mlibuf.equ \
                  $(INC)/mm.annex.equ $(INC)/mm.annex2.equ \
                  $(INC)/mm.main.equ \
                  $(INC)/mm.kbss.equ

# inc/syscall.equ + inc/errno.equ split (2026-08-20, docs/
# SELFHOST-CONVERSION.md phase 1): together ~9.8KB PUT whole by every
# compilation unit -- the largest remaining universal cost after
# memmap.equ. Split per concern from a reference-set scan (which .s
# files, AND which scripts/*.py, actually name each symbol); see
# docs/SYSCALL.md for the grouping. Same MEMMAP_ALL-style whole-set
# convention: conservative-safe to over-list as a Make dependency even
# where a given manifest PUTs only a subset.
SYSCALL_ALL    := $(INC)/sc.proc.equ \
                  $(INC)/sc.status.equ \
                  $(INC)/sc.file.equ \
                  $(INC)/sc.fd.equ \
                  $(INC)/sc.devfd.equ \
                  $(INC)/sc.fdact.equ \
                  $(INC)/errno.krn.equ \
                  $(INC)/errno.spawn.equ

# The six per-subsystem equ files OUTSIDE the two whole-set groups
# above, PUT by every kernel-bearing manifest. Found 2026-08-23 (S4)
# by check_manifests.py's full-closure coverage check: none of them
# was a dependency of ANY test-image rule, so editing e.g.
# inc/bankcopy.equ (BC_KIND_BANK's home) re-ran every gate on a
# stale image, green. Same whole-set over-listing convention as
# MEMMAP_ALL/SYSCALL_ALL.
EQU_KERNEL     := $(INC)/bankcopy.equ \
                  $(INC)/bankprobe.equ \
                  $(INC)/entry.frame.equ \
                  $(INC)/mli.const.equ \
                  $(INC)/sched.equ \
                  $(INC)/ultraterm.equ \
                  $(INC)/proc.const.equ \
                  $(INC)/sched.zp.equ \
                  $(INC)/kdisp.equ \
                  $(INC)/timer.equ \
                  $(INC)/tty.equ

BOOTBLK        := $(BUILD)/bootblock.bin
IMAGE          := $(BUILD)/maux.po
IMAGE_BLOCKS   := 800

CHECKMEMMAP    := $(BUILD)/check_memmap.bin

# task #5: boot-time RamWorks bank probe + free-list allocator test image.
# src/test/probetest.s PUTs in src/kernel/bankprobe.s (the actual probe/
# allocator module) -- see both files' headers.
PROBEBLK       := $(BUILD)/probetest.bin
PROBEIMAGE     := $(BUILD)/probetest.po

VERILOGAPPLE       ?= $(HOME)/src/verilogapple
# The build tier has no emulator. A host that happens to have an unlocked
# ~/src/verilogapple must not let a gate run against it (the supervisor file
# would exist, so make would skip the rule that names the tier): point at a
# path that cannot exist. docs/DEPS-TIER-NOTES.md P4.
ifeq ($(MAUX_TIER),build)
override VERILOGAPPLE := $(DEPS_ROOT)/verilogapple.absent-in-the-build-tier
endif
MCP_SUPERVISOR     := $(VERILOGAPPLE)/sim/mcp/obj_dir/mcp_supervisor
export VERILOGAPPLE
export MAUX_SUPERVISOR ?= $(abspath $(MCP_SUPERVISOR))
export VERILOGAPPLE_ROMS ?= $(abspath $(VERILOGAPPLE)/sim/roms)

# ProDOS 2.4 is the boot kernel (ruling 2026-10-08, docs/PRODOS-VERSION.md
# and docs/PRODOS-CASE.md): the 2026-08-17 "target 2.5" ruling is
# withdrawn -- 2.5's Extended dates make the volume no longer ProDOS, and
# its root growth and alpha status are not wanted. The one 2.5 property
# maux keeps is GS/OS case-preserving names, which the kernel writes
# itself. History: from 2026-08-19 to 2026-10-08 this line said 2.5 while
# a spike's global `PRODOSBIN :=` override below made every image boot
# 2.4 anyway; nothing read the version off an image. check-prodos-version
# (in check-all) now does. Override only to measure another kernel.
PRODOSBIN          ?= vendor/ProDOS-2.4.bin
export PRODOS_KERNEL_BIN ?= $(abspath $(PRODOSBIN))

LIBA           := $(SRC)/liba
BINSRC         := $(SRC)/bin
# task (sh/ed): new userland tools are added to the same build/size-table/
# choke-point pattern every other util already uses -- no new machinery.
UTILS          := echo cat ls cp rm sh ed ex grep wc mkdir mv pwd ps as touch \
                  cmp sort uniq tr od file \
                  tail head nm find diff expr du tee comm \
                  sum date chmod df sed sleep time make chvt vidmode kill more \
                  stty reset true false vi tip cut xargs printf \
                  basename dirname env \
                  uuencode uudecode \
                  rmdir tty uname \
                  cksum paste fold \
                  nl expand unexpand \
                  man cal strings \
                  dd bpatch plasma proshim \
                  nohup \
                  timeout \
                  realpath \
                  tsort pr pathchk \
                  split \
                  csplit \
                  join \
                  patch \
                  shutdown \
                  chtyp \
                  nulib2 \
                  mount umount \
                  bye
UTIL_BINS      := $(addprefix $(BUILD)/,$(addsuffix .bin,$(UTILS)))
# liba's seven headers moved to inc/ alongside the ABI equates when
# the host and guest layouts were unified (docs/LAYOUT.md, 2026-09-16).
# Named one by one rather than $(wildcard $(INC)/*.equ): that wildcard
# would charge every liba consumer with the 27 kernel equates as well,
# and this list is exactly what $(LIBA)/*.equ used to match.
LIBA_EQUS      := $(INC)/zp.equ $(INC)/stdio.equ $(INC)/startup.equ \
                  $(INC)/mli.equ $(INC)/regex.equ $(INC)/readdir.equ \
                  $(INC)/cptree.equ
LIBA_SRCS      := $(wildcard $(LIBA)/*.s) $(LIBA_EQUS)

# task #3: $FFxx page + JSR $FF00 syscall ABI acceptance gate.
FFPAGESIZEBLK  := $(BUILD)/ffpage_size.bin
SYSCALLBLK     := $(BUILD)/syscalltest.bin
SYSCALLIMAGE   := $(BUILD)/syscalltest.po

# task #4: bank-clone core (src/kernel/bankcopy.s). check-bankcopy is the
# PRIMARY GATE (the 2x2x2 softswitch-state matrix); writelanding is the
# separate [likely]-grade experiment (docs/TASKS.md #4 deliverable 3),
# not part of the pass/fail gate -- see scripts/experiment_writelanding.py.
BANKCOPYBLK     := $(BUILD)/bankcopytest.bin
BANKCOPYIMAGE   := $(BUILD)/bankcopytest.po
WRITELANDBLK    := $(BUILD)/writelanding.bin
WRITELANDIMAGE  := $(BUILD)/writelanding.po

# task #6: scheduler/context-switch/timer-driver acceptance gate. Two
# variants sharing src/test/sched.common.s -- see that file's header and
# docs/SCHED.md. Built with `-v1` (not just a plain assemble): merlin32's
# own symbol-table dump (build/<name>.bin_Output.txt) is how
# scripts/check_sched.py recovers `ds`-placed kernel-global addresses,
# which are NOT fixed and shift whenever kernel source size changes --
# see that script's header for why hardcoding them would be wrong.
SCHEDPREEMPTBLK   := $(BUILD)/schedtest_preempt.bin
SCHEDPREEMPTIMAGE := $(BUILD)/schedtest_preempt.po
SCHEDCOOPBLK      := $(BUILD)/schedtest_coop.bin
SCHEDCOOPIMAGE    := $(BUILD)/schedtest_coop.po
SCHEDWAKEBLK      := $(BUILD)/schedtest_wake.bin
SCHEDWAKEIMAGE    := $(BUILD)/schedtest_wake.po
SCHED_DEPS        := $(SRC)/test/sched.common.s $(SRC)/kernel/entry.s \
                      $(SRC)/kernel/entry2.s \
                      $(SRC)/kernel/ffpage.s $(SRC)/kernel/sched.s \
                      $(SRC)/kernel/sched2.s $(SRC)/kernel/procsig.s \
                      $(SRC)/kernel/timer.s $(SRC)/kernel/mouse.s \
                      $(MEMMAP_ALL) \
                      $(SYSCALL_ALL) $(EQU_KERNEL)

# EVERY module the process-bearing test images PUT, in ONE place. The
# per-gate lists used to name entry/ffpage/sched/bankcopy/process and stop
# there, while the images themselves also PUT procspawn.s, procfd.s, tty.s
# and ultraterm.s -- so editing the spawn path did not rebuild
# check-process, check-catread, check-sh, check-fileprocess or check-ed,
# and those gates re-ran the PREVIOUS binary and reported PASS. That is
# the identical failure PLAYTEST_DEPS' own comment records against
# check-play on 2026-08-17; it was fixed there and left in place here.
# Found again while rewriting PSTG_ARGV (docs/LIMITS.md), whose whole
# blast radius is procspawn.s.
#
# The `...testb.s` bodies were missing too, for the same reason: the
# manifest is thin and the body holds the actual test.
KERNEL_PROC_MODS := $(SRC)/kernel/entry.s $(SRC)/kernel/entry2.s \
                     $(SRC)/kernel/ffpage.s $(SRC)/kernel/kdisp.s \
                     $(SRC)/kernel/sched.s $(SRC)/kernel/sched2.s \
                     $(SRC)/kernel/bankcopy.s \
                     $(SRC)/kernel/process.s $(SRC)/kernel/process2.s $(SRC)/kernel/procfile.s $(SRC)/kernel/procfile4.s \
                     $(SRC)/kernel/procfile2.s \
                     $(SRC)/kernel/procfile3.s $(SRC)/kernel/procfile5.s \
                     $(SRC)/kernel/ultraterm.s $(SRC)/kernel/ultraterm2.s \
                     $(SRC)/kernel/tty.s $(SRC)/kernel/tty3.s $(SRC)/kernel/tty2.s $(SRC)/kernel/tty4.s $(SRC)/kernel/tty5.s $(SRC)/kernel/tty6.s $(SRC)/kernel/tty7.s $(SRC)/kernel/tty8.s $(SRC)/kernel/tty9.s \
                     $(SRC)/kernel/procspawn.s $(SRC)/kernel/procspawn3.s \
                     $(SRC)/kernel/spawnbl.s $(SRC)/kernel/spawnpl.s \
                     $(SRC)/kernel/procspawn2.s $(SRC)/kernel/procsig.s $(SRC)/kernel/procsig2.s \
                     $(SRC)/kernel/procfd.s $(SRC)/kernel/procfd2.s $(SRC)/kernel/procmli.s $(SRC)/kernel/procmli3.s $(SRC)/kernel/procmli2.s \
                     $(SRC)/kernel/lazyfree.s \
                     $(SRC)/kernel/procfork.s \
                     $(SRC)/kernel/ser.s \
                     $(SRC)/kernel/procbye.s \
                     $(SRC)/kernel/procdev.s $(SRC)/kernel/procdevs.s $(SRC)/kernel/vroot.s \
                     $(MEMMAP_ALL) $(SYSCALL_ALL) $(EQU_KERNEL) \
                     $(wildcard $(INC)/*.equ)

# task #12: process syscalls and pipe/fdactions integration gate.
PROCESSBLK       := $(BUILD)/processtest.bin
PROCESSIMAGE     := $(BUILD)/processtest.po
FILECHILDBIN     := $(BUILD)/fchild.bin
FILEPROCESSBLK   := $(BUILD)/MAUXFILEPROC.SYSTEM
FILEPROCESSIMAGE := $(BUILD)/fileprocess.po
ECHOBIN          := $(BUILD)/echo.bin
PROCESS_DEPS     := $(SRC)/test/processtest.s $(SRC)/test/processtestb.s $(SRC)/test/processtestb2.s \
                     $(KERNEL_PROC_MODS)
FILEPROCESS_DEPS := $(SRC)/test/fileproctest.s \
                     $(SRC)/test/fileproctestb.s $(KERNEL_PROC_MODS)
STICKYBLK        := $(BUILD)/MAUXSTICKY.SYSTEM
STICKYIMAGE      := $(BUILD)/sticky.po
STICKY_DEPS      := $(SRC)/test/stickytest.s $(SRC)/test/stickytestb.s \
                     $(KERNEL_PROC_MODS)

# ARG_MAX byte-budget gate (docs/LIMITS.md): argv exactly at the ceiling
# must arrive whole, one byte past must ERROR. Raw block image -- spawn and
# wait are all it needs, so no ProDOS.
ARGVBLK          := $(BUILD)/argvtest.bin
ARGVIMAGE        := $(BUILD)/argvtest.po
ARGV_DEPS        := $(SRC)/test/argvtest.s $(SRC)/test/argvtestb.s \
                     $(KERNEL_PROC_MODS)

# Spawn fdactions validation gate (docs/DUPFD-1.md phase K). Raw block
# image like argvtest; spawn/pipe/wait are all it needs.
FDABLK           := $(BUILD)/fdatest.bin
FDAIMAGE         := $(BUILD)/fdatest.po
FDA_DEPS         := $(SRC)/test/fdatest.s $(SRC)/test/fdatestb.s \
                     $(KERNEL_PROC_MODS)
FDAPBLK          := $(BUILD)/fdatestp.bin
FDAPIMAGE        := $(BUILD)/fdatestp.po
FDAP_DEPS        := $(SRC)/test/fdatestp.s $(SRC)/test/fdatestb.s \
                     $(KERNEL_PROC_MODS)

# fork() acceptance image (docs/FORK.md). Raw block image; see the
# check-fork recipe below.
FORKBLK          := $(BUILD)/forktest.bin
FORKIMAGE        := $(BUILD)/forktest.po
FORK_DEPS        := $(SRC)/test/forktest.s $(SRC)/test/forktestb.s \
                     $(SRC)/kernel/procfork.s $(KERNEL_PROC_MODS)


.PHONY: verify-mirror
.PHONY: preflight check-teeth-lib check-sessions-fresh check-teeth-patterns check-sweep-par check-kledger kledger check-carrier man-pages play release check-release-image bootstrap-deps check-deps-selftest check-all-cross check-all-box check-all-box-par check-all-cross-par check-deps check-selfhost check-kernel-images env-image check-env all image clean check-bytes check-dual check-all maux-src-image check-memmap check-userland vendor-prodos vendor-merlin check-asmspike check-modules rel-image check-rel merlin-src-image check-merlin ascore-image check-ascore ascore-process-image check-ascore-process check-ascore-warm ascore-warm-image bufio-image check-bufio sh-image check-sh shlang-image check-shlang play-image check-play v1-system-image bin-image check-v1-system ed-image check-ed ex-image check-ex glob-image check-glob check-argv check-fdact vendor-mame-roms ls-image check-ls as-image check-as ld-image check-ld seek-image check-fleet testev-image check-testev tail-image check-tail nm-image check-nm find-image check-find diff-image check-diff expr-image check-expr du-image check-du comm-image check-comm sumdate-image check-sumdate chmod-image check-chmod textaudit-image check-textaudit shwarm-image check-shwarm e2e-image check-e2e check-e2e-host writefail-image check-writefail-host dirfull-image check-dirfull-host check-dialect check-stagebin check-strip sed-image check-sed check-regex check-posixsed check-posixutil vendor-fowler check-fowler check-posix report-volumes check-shedit check-tabcomp check-release-pack release-candidate release-version-check verify-remote \
e2efs-image check-e2e-fs-host check-e2e-fs report-liba \
jobctl-image check-jobctl-b \
vendor-ftn proshim-image check-proshim check-mlival dd-image check-dd partition-image check-partition devblk-image check-devblk floppy-image check-floppy devfs-image check-devfs check-mount check-exec check-brk check-ps check-devpath check-shfd check-shprefix check-shnlvar check-shforeign check-shmlquote check-shexecloop check-shseq check-openrw check-openrw2 check-openrw2-k check-oappend check-oappend-sh check-open-census check-encoding-census check-loop check-lseg df-image check-df unpack-image check-unpack bpatch-image check-bpatch plasma-image check-plasma plasm-image check-plasm nas-image check-nas nas-rel-image check-nas-rel nas-real-image check-nas-real nas-librel-image check-nas-librel nas-selfmake-image check-nas-selfmake-image check-nas-selfmake full-image check-full check-plasm-full check-examples check-plasma-examples check-liba-pins plascut-image check-plascut profile-image profile-nas

all: $(IMAGE)

# TIER=test (default) needs ROM_DIR; TIER=build needs nothing from the
# operator and fetches no Forgejo repository (docs/DEPENDENCIES.md).
bootstrap-deps:
	@test "$(TIER)" = build -o -n "$(ROM_DIR)" || { \
		echo "ROM_DIR is required for TIER=test (see docs/DEPENDENCIES.md); TIER=build needs none"; exit 2; }
	python3 $(SCRIPTS)/bootstrap_dependencies.py \
		--dest "$(DEPS_ROOT)" --tier "$(or $(TIER),test)" \
		$(if $(ROM_DIR),--rom-dir "$(ROM_DIR)") \
		$(if $(A2TIL_SOURCE),--a2til-source "$(A2TIL_SOURCE)")

# Audits the tier the tree was bootstrapped as; `make check-deps
# TIER=test` on a build-tier tree fails naming the tier.
check-deps:
	python3 $(SCRIPTS)/check_dependencies.py --deps-root "$(DEPS_ROOT)" \
		$(if $(TIER),--tier $(TIER))

# The whole audit plus the one thing no sweep gate does: fetch the GitHub
# a2til pin and hold it to the lock's content manifest (needs the network).
# This is the documented release-checklist command; unlike the bare script
# it needs no sourced .deps/activate (RC-1 F2).
verify-mirror:
	python3 $(SCRIPTS)/check_dependencies.py --deps-root "$(DEPS_ROOT)" \
		--verify-mirror $(if $(TIER),--tier $(TIER))

# Every commit the lock pins (and the PyPI files) must be FETCHABLE from its
# lock URL by a stranger: no checkout, no credentials, empty scratch repo
# (RC-1 F1: verilogapple 296d93a was on the dev host and not on the Forgejo,
# and no gate noticed, because every gate runs against a local checkout).
# Needs the network, so it is NOT in the offline sweep: `make release` and
# `make release-candidate` run it first, before anything builds. It reads
# only the lock -- no .deps tree, no tier.
verify-remote:
	python3 $(SCRIPTS)/check_dependencies.py --verify-remote

# Plants a fault in each lock check (the a2til mirror-pin drift, the PyPI
# source commit, a pinned object's length, a flipped digit in a LIBA pin)
# and requires each to come back red.
check-deps-selftest:
	python3 $(SCRIPTS)/check_dependencies.py --selftest
	python3 $(SCRIPTS)/bootstrap_dependencies.py --selftest

# HYG-2: scripts/sweep_par.sh must not report a sweep green when it ran
# fewer gates than it launched (a 400-character CHECKLOGDIR once made xargs
# die before running one; the sweep printed its count and exited 0). A stub
# `make` stands in for the gates, so this is hermetic and takes seconds:
# rows for a normal sweep, a red gate, the long CHECKLOGDIR, a killed
# serial lane, a killed play.po lane, a killed xargs worker and a repeated
# target. It needs only bash and python3, so it runs on both hosts.
check-sweep-par:
	$(SWEEP_SH) $(SCRIPTS)/sweep_par_selftest.sh

$(BUILD):
	mkdir -p $@

# merlin32's `dsk ../build/bootblock.bin` directive in src/bootblock.s
# resolves relative to the SOURCE file's directory, not CWD (see
# learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0), so this always lands at exactly
# $(BOOTBLK) regardless of caller CWD. The `typ $00` directive spills a
# _FileInformation.txt sidecar we don't need (no ProDOS type is meaningful
# for a raw block image) -- delete it, same as malisp's Makefile.
$(BOOTBLK): $(SRC)/bootblock.s | $(BUILD)
	$(MERLIN32) $(SRC)/bootblock.s
	@rm -f $(SRC)/_FileInformation.txt
	@test -f $(BOOTBLK) || { echo "missing $(BOOTBLK)"; ls -la $(BUILD); exit 1; }

image: $(IMAGE)

# Deterministic: output is a pure function of bootblock.bin's bytes and
# IMAGE_BLOCKS -- no timestamps, no filesystem, byte-identical on rebuild.
$(IMAGE): $(BOOTBLK) $(SCRIPTS)/build_image.py
	python3 $(SCRIPTS)/build_image.py $(BOOTBLK) $(IMAGE) $(IMAGE_BLOCKS)

# Build the MCP supervisor + worker if not already built. Per the task
# contract: build and use verilogapple, never modify it (another agent
# works that repo in a separate worktree).
ifeq ($(MAUX_TIER),build)
$(MCP_SUPERVISOR):
	@echo "this tree was bootstrapped with TIER=build: it has no verilogapple, so the emulator gates cannot run here."; \
	echo "Provision the test tier (make bootstrap-deps ROM_DIR=... into a new DEPS_ROOT, docs/DEPENDENCIES.md)."; exit 2
else
$(MCP_SUPERVISOR):
	$(MAKE) -C $(VERILOGAPPLE) mcp
endif


# check-memmap (task #2): pure assembler smoke test, no emulator involved --
# proves merlin32 accepts the split memmap includes (`use`, `dum`/`dend`,
# `equ` -- $(MEMMAP_ALL), docs/SELFHOST-CONVERSION.md phase 1) by
# assembling src/check.memmap.s, a trivial program that references one
# symbol from every major section of the shared memory-map symbol files
# (docs/MEMMAP.md). Same sidecar-cleanup idiom as $(BOOTBLK) above --
# `typ $00`'s _FileInformation.txt sidecar is meaningless for a throwaway
# check binary.
$(CHECKMEMMAP): $(SRC)/check.memmap.s $(MEMMAP_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/check.memmap.s
	@rm -f $(SRC)/_FileInformation.txt
	@test -f $(CHECKMEMMAP) || { echo "missing $(CHECKMEMMAP)"; ls -la $(BUILD); exit 1; }

check-memmap: $(CHECKMEMMAP)
	python3 $(SCRIPTS)/check_memmap_zp.py

# task #5's acceptance gate. merlin32's `dsk` directive in src/test/probetest.s
# resolves relative to THAT source file's directory (src/test/), same
# convention as bootblock.s -- so this always lands at exactly $(PROBEBLK).
$(PROBEBLK) $(PROBEBLK)_Output.txt: $(SRC)/test/probetest.s $(SRC)/kernel/bankprobe.s $(MEMMAP_ALL) $(SYSCALL_ALL) $(EQU_KERNEL) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/probetest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(PROBEBLK) || { echo "missing $(PROBEBLK)"; ls -la $(BUILD); exit 1; }
	@test -f $(PROBEBLK)_Output.txt || { echo "missing $(PROBEBLK)_Output.txt"; exit 1; }

$(PROBEIMAGE): $(PROBEBLK) $(SCRIPTS)/build_image.py
	python3 $(SCRIPTS)/build_image.py $(PROBEBLK) $(PROBEIMAGE) $(IMAGE_BLOCKS)


# ---------------------------------------------------------------------------
# task #10 (early-start userland slice): liba + the five draft-ABI utils.
#
# There is no kernel yet, so these cannot RUN -- the gate is "assembles
# clean with merlin32, one flat binary per util (liba is `put`-included
# into each, since merlin32 has no separate linker/relocation step -- see
# docs/USERLAND.md)" plus a size table, plus mechanical enforcement of the
# $FF00 choke point: nothing outside src/liba may mention the gate address
# or a raw call number (SYS_*) -- only src/liba/syscalls.{s,equ} may, and
# utils must go through the SC_* wrappers. This is what makes task #3's
# eventual ABI landing a sweep of two files instead of a rewrite of five.
# ---------------------------------------------------------------------------
$(BUILD)/%.bin: $(BINSRC)/%.s $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(BINSRC)/$*.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; ls -la $(BUILD); exit 1; }

# sh.s `put`s testeval.s directly (docs/SH-SUBSET.md sec 6.3 -- `test`
# is a shell BUILTIN, not a binary), so sh.bin's own dependency needs to
# name it explicitly -- the generic pattern rule above only tracks
# $(BINSRC)/sh.s itself and $(LIBA_SRCS), not a sibling bin/ file pulled
# in by `put`.
# SH_PUT_MODS -- sh.s's body modules (S9, 2026-08-28). Named as a
# variable because FIVE rules already list sh.s as a source and each of
# them is equally stale without the bodies; check-manifests fails any
# rule that misses one.
SH_PUT_MODS := $(BINSRC)/shlex.s \
                $(BINSRC)/shtok.s \
                $(BINSRC)/shcls.s \
                $(BINSRC)/shexpand.s \
                $(BINSRC)/shexp2.s \
                $(BINSRC)/shsubst.s \
                $(BINSRC)/shsub2.s \
                $(BINSRC)/shparse.s \
                $(BINSRC)/shresv.s \
                $(BINSRC)/shrsv2.s \
                $(BINSRC)/shvar.s \
                $(BINSRC)/shvar2.s \
                $(BINSRC)/shbltn.s \
                $(BINSRC)/shblt2.s \
                $(BINSRC)/shpath.s \
                $(BINSRC)/shpth2.s \
                $(BINSRC)/shtrap.s \
                $(BINSRC)/shjob.s \
                $(BINSRC)/shblt3.s \
                $(BINSRC)/shalias.s \
                $(BINSRC)/shsegi.s \
                $(BINSRC)/shsgtrp.s \
                $(BINSRC)/shsggop.s \
                $(BINSRC)/shsgjob.s \
                $(BINSRC)/shsgblt.s \
                $(BINSRC)/shsgbl2.s \
                $(BINSRC)/shsgali.s \
                $(BINSRC)/shsgglb.s \
                $(BINSRC)/shsgsig.s \
                $(BINSRC)/shedit.s \
                $(BINSRC)/shtabc.s \
                $(BINSRC)/shtabc2.s \
                $(BINSRC)/shpfx.s \
                $(BINSRC)/shsgrw.s \
                $(BINSRC)/shsgmlq.s \
                $(BINSRC)/shrlog.s \
                $(BINSRC)/shlex2.s \
                $(BINSRC)/shedit2.s \
                $(BINSRC)/shsgcld.s

# sh.s is a MANIFEST since 2026-08-28 (S9): its body lives in eight put
# modules, split for check-dialect's source-buffer budget. Same reason as
# testeval.s -- the generic pattern rule tracks only sh.s itself, so
# without these, editing a body module rebuilds nothing and every gate
# runs green against a stale image.
$(BUILD)/sh.bin: $(BINSRC)/testeval.s $(SH_PUT_MODS)

# sed.s `put`s sedexec.s (split for check-dialect's source-buffer
# budget), so sed.bin's dependency needs the split half too.
# The tier-2 main splits (S9): each fat manifest's body modules,
# same staleness reason as sed.bin above.
$(BUILD)/diff.bin: $(BINSRC)/difftop.s $(BINSRC)/difflpb.s \
                   $(BINSRC)/diffhnk.s $(BINSRC)/diffctx.s \
                   $(BINSRC)/diffcout.s $(BINSRC)/diffrec.s \
                   $(BINSRC)/diffdir.s
# patch.s `put`s five body modules -- patchio.s (options, the
# patch stream's line reader, the hunk arena), patchtgt.s (the
# target file's read and the output's creation), patchwr.s (the
# writers and the loud exits), patchhnk.s (format detection,
# names, numbers) and patchprs.s (the three hunk parsers) --
# split against check-dialect's 16,128-byte as-window, which new
# code must fit from birth: the unsplit pair measured 18,876 B
# stripped for one module against a 4,740 B manifest. Same
# staleness reason as sed.bin above: the pattern rule tracks
# only patch.s itself.
$(BUILD)/patch.bin: $(BINSRC)/patchio.s $(BINSRC)/patchtgt.s \
                    $(BINSRC)/patchwr.s $(BINSRC)/patchhnk.s \
                    $(BINSRC)/patchprs.s $(BINSRC)/patchapp.s

$(BUILD)/find.bin: $(BINSRC)/findtop.s $(BINSRC)/findact.s \
                   $(BINSRC)/findexpr.s $(BINSRC)/findeval.s \
                   $(BINSRC)/findtst.s
# proshim (TASKS.md #19): three pieces assembled standalone at their
# real addresses ($BF00 page, $E000 core, $F941 ROM stubs) and
# embedded in proshim.bin via putbin -- the as-stubs.bin mechanism.
$(BUILD)/proshim.bin $(BUILD)/proshim.bin_Output.txt: $(BINSRC)/proshim.s \
                      $(BINSRC)/proshim.equ $(BUILD)/proshimpg.bin \
                      $(BUILD)/proshimcr.bin \
                      $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) -v1 $(BINSRC)/proshim.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $(BUILD)/proshim.bin || { echo "missing proshim.bin"; exit 1; }
$(BUILD)/proshimpg.bin $(BUILD)/proshimpg.bin_Output.txt: \
                        $(BINSRC)/proshimpg.s $(BINSRC)/proshim.equ \
                        $(MEMMAP_ALL) | $(BUILD)
	$(MERLIN32) -v1 $(BINSRC)/proshimpg.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
$(BUILD)/proshimcr.bin: $(BINSRC)/proshimcr.s $(BINSRC)/proshim.equ \
                        $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(BINSRC)/proshimcr.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
# byeres (docs/BYE-SLICE1.md): the `bye` resident, assembled
# standalone at $D100. NOT putbin'd into any kernel image any
# more (2026-09-25, the PT_HOLD ceiling overrun this file's own
# kernel growth caused): it is DATA, loaded from disk at `bye`
# time by procbye.s's PBY_LOAD_RES, so this is now a play-image
# STAGED ASSET (see play-image's own prerequisite line) rather
# than a PLAYTEST_DEPS assembly input -- playtest.s no longer
# PUTs/putbins it at all, so listing it under KERNEL_PROC_MODS
# would trigger rebuilds nothing reads.
$(BUILD)/byeres.bin $(BUILD)/byeres.bin_Output.txt: \
                    $(SRC)/kernel/byeres.s $(INC)/byeres.equ \
                    $(INC)/mm.hw.equ | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/kernel/byeres.s
	@rm -f $(SRC)/kernel/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
# byelaunch.s/byefull.bin RETIRED 2026-09-27 (docs/KSEG.md): the `bye
# PATH.SYSTEM` launch is no longer a standalone assembly concatenated
# onto byeres.bin -- it is `put` directly into playtest.s's own `org
# KSEG_ORG` block (src/kernel/byelaunch.s has no `org`/`dsk`/`typ`/`put`
# header of its own any more) and staged as build/MAUXPLAY_KSEG by
# scripts/split_kseg.py, part of the $(PLAYTESTBLK) rule above. BYERES
# is byeres.bin alone again.
$(BUILD)/proshim-toy.bin: $(SRC)/test/proshimtoy.s | $(BUILD)
	$(MERLIN32) $(SRC)/test/proshimtoy.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
# byetenant.bin -- the `bye PATH.SYSTEM` launch's own worked
# example and gate fixture (docs/BYE.md "Slice 2 launch"). A real
# ProDOS 8 .SYSTEM, staged on play.po as /mnt/MAUX/BYETENANT.SYSTEM.
$(BUILD)/byetenant.bin: $(SRC)/test/byetenant.s | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/byetenant.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
# byetenantd.bin -- the S4 tenant that deletes the loop image
# (docs/LOOP-S2.md), staged as /mnt/MAUX/DELTEN.SYSTEM.
$(BUILD)/byetenantd.bin: $(SRC)/test/byetenantd.s | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/byetenantd.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
# byetenantr.bin -- the KFIX2 item 4 tenant that rewrites a program
# (SET_EOF 0 on /MAUX/RWT with raw MLI), staged by check_tenant.py.
$(BUILD)/byetenantr.bin: $(SRC)/test/byetenantr.s | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/byetenantr.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
$(BUILD)/mlival.bin: $(SRC)/test/mlival.s | $(BUILD)
	$(MERLIN32) $(SRC)/test/mlival.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }
$(BUILD)/ls.bin: $(BINSRC)/lstop.s $(BINSRC)/lssort.s \
                 $(BINSRC)/lsrec.s $(BINSRC)/lsprint.s \
                 $(BINSRC)/lscol.s
$(BUILD)/mv.bin: $(BINSRC)/mvtop.s $(BINSRC)/mvcopy.s
$(BUILD)/cmp.bin: $(BINSRC)/cmprpt.s
$(BUILD)/sort.bin: $(BINSRC)/sortcmp.s $(BINSRC)/sortkey.s $(BINSRC)/sortnum.s
$(BUILD)/cp.bin: $(BINSRC)/cpdir.s $(BINSRC)/cpcopyd.s
$(BUILD)/dd.bin: $(BINSRC)/ddparse.s $(BINSRC)/ddcopy.s
$(BUILD)/bpatch.bin: $(BINSRC)/bpatchp.s $(BINSRC)/bpatchd.s
$(BUILD)/plasma.bin $(BUILD)/plasma.bin_Output.txt: $(BINSRC)/plasma.s \
                   $(BINSRC)/plasmavm.s $(BINSRC)/plasmals.s \
                   $(BINSRC)/plasmaop.s $(BINSRC)/plasmald.s \
                   $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) -v1 $(BINSRC)/plasma.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $(BUILD)/plasma.bin || { echo "missing plasma.bin"; exit 1; }
$(BUILD)/rm.bin $(BUILD)/cp.bin $(BUILD)/mv.bin: $(LIBA)/cptree2.s
$(BUILD)/nm.bin: $(BINSRC)/nmtop.s $(BINSRC)/nmscan.s

$(BUILD)/sed.bin: $(BINSRC)/sedparse.s $(BINSRC)/sedexec.s \
                  $(BINSRC)/sedsel.s $(BINSRC)/sedio.s \
                  $(BINSRC)/sedout.s

# more.bin puts morefile.s/moreio.s/moreshow.s/morecmd.s (the pager,
# 2026-09-12) -- same staleness reason as sed.bin above.
$(BUILD)/more.bin: $(BINSRC)/morefile.s $(BINSRC)/moreio.s \
                   $(BINSRC)/moreshow.s $(BINSRC)/morecmd.s

# make.s is a MANIFEST and nothing else: its body is makeargs.s (the
# command line), makeread.s + makehdr.s (the makefile reader and the
# rule parser), makemac.s + makeexp.s (the macro table and the one
# expander),
# makeinf.s + makeinf2.s + makeprt.s (special targets, inference, and
# -p) and makerun.s + makedec.s + makespn.s (the dependency walk, the
# mod-time comparison and the recipe runner). Eleven files, not three
# because as holds the manifest resident and streams one put at a
# time, so the charge is manifest + LARGEST put against a 16,128-byte
# window (check-dialect 3b) -- and because, without this dependency
# line, editing a body module rebuilds nothing and every gate runs
# green on a stale image.
$(BUILD)/make.bin: $(BINSRC)/makeargs.s $(BINSRC)/makeread.s \
                   $(BINSRC)/makehdr.s $(BINSRC)/makemac.s \
                   $(BINSRC)/makeexp.s $(BINSRC)/makeinf.s \
                   $(BINSRC)/makeinf2.s $(BINSRC)/makeprt.s \
                   $(BINSRC)/makerun.s $(BINSRC)/makedec.s \
                   $(BINSRC)/makespn.s

# mld.s -- the MERLIN linker: maux's bridge around Merlin's own
# LINKER.S, which it embeds and whose MLI calls it emulates. It was
# called `ld` until the native linker replaced it; `mld` says what it
# actually is. It `put`s mldload.s (the streaming module loader,
# split out when it pushed the unit past real Merlin's 41,215-byte
# source buffer). Same reason as sed.bin below.
$(BUILD)/mld.bin: $(BINSRC)/mldload.s

# ld.s -- THE linker (docs/LD-NATIVE.md): native, two-pass, with
# library search. It `put`s ldpass.s/ldsym.s/ldpass2.s (split for
# as's source window, which is what lets maux rebuild its own
# linker) and ldlib.s (-L/-l). Its `dum LIBA_BSSEND` arena is INLINE
# at the end of ld.s, the house idiom (make.s's precedent).
# ld, proshim, plasma and proshimpg are built `-v1` so their listings
# exist: the self-host sweep (build_nas_librel_image split mains) cuts
# ld's REL main in two from it and literalizes the PC equates / `ds
# EXPR-*` pads of the other three (gen_rel_module.generate_split_main).
$(BUILD)/ld.bin $(BUILD)/ld.bin_Output.txt: $(BINSRC)/ld.s \
                 $(BINSRC)/ldpass.s $(BINSRC)/ldsym.s \
                 $(BINSRC)/ldpass2.s $(BINSRC)/ldstream.s \
                 $(BINSRC)/ldzout.s \
                 $(BINSRC)/ldout.s \
                 $(BINSRC)/ldlib.s $(BINSRC)/ldscan.s \
                 $(BINSRC)/ldargf.s \
                 $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) -v1 $(BINSRC)/ld.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $(BUILD)/ld.bin || { echo "missing ld.bin"; exit 1; }

# uniq.s `put`s TWO files: uniqio.s (the buffered input layer
# GETLINE/GETBYTE/REFILL, the S9-PLAN sec 5 W4 rehearsal) and
# uniqcmp.s (the comparison and run-output layer SAVEPREV/SKIPCMP/
# SK_ADV/ISBLANK/PARSENUM8/BUMPRUN/ISDUP/OUTRUN/PRCNT, added
# 2026-09-17 when -f/-s put uniq.s back over the window at 18,192 B
# stripped, 2,066 over). Same reason as sed.bin above.
$(BUILD)/uniq.bin: $(BINSRC)/uniqio.s $(BINSRC)/uniqcmp.s

# cut.s `put`s cutlist.s (LIST-syntax parser, split for the same
# as-window budget). Same reason as sed.bin above.
$(BUILD)/cut.bin: $(BINSRC)/cutlist.s

# paste.s `put`s pastepar.s (the PARALLEL/merge mode: OPENALL/
# CLOSEALL/GETBYTEM/REFILLM/GETLINEM/EMITFIELDM/MERGERUN), split
# for the same as-window budget -- paste.s alone measured 18,690 B
# stripped, over the 16,128-byte window. Same reason as sed.bin
# above.
$(BUILD)/paste.bin: $(BINSRC)/pastepar.s

# unexpand.s `put`s uxrun.s (the per-line engine: UXFD/PENDPUSH/
# PENDLIT/FLUSHRUN/ISSTOP/NEXTSTOP/PERSTOP), split for the same
# as-window budget -- unexpand.s alone measured 16,572 B
# stripped, over the 16,128-byte window. Same reason as sed.bin
# above.
$(BUILD)/unexpand.bin: $(BINSRC)/uxrun.s

# nl.s `put`s TWO files: nlopt.s (option-value parsers: SETPTRO/
# PARSETY/PARSED/PARSEI/PARSEN/PARSES/PARSEV/ACCUM16/PARSEW2) and
# nlfmt.s (the per-line engine: BUILDMK/NLRUN/RESETNUM/PRINTONE/
# PRINTNUM/PRINTBLANK/ADVANCE/EMITLINE/CHECKHDR/CHECKBODY/
# CHECKFOOT/READLINE) -- nl.s alone measured 24,534 B stripped,
# over the 16,128-byte window. The as-window check counts
# resident + the SINGLE LARGEST put, not the sum of every put,
# so one put file big enough to close the gap (11,557 B) would
# itself have become the new largest-put term and left the unit
# over budget again (7,475 resident + 11,557 = 19,032); two
# balanced put files (6,002 B / 5,564 B) instead give 7,475 +
# 6,002 = 13,477, comfortably under. Same as-window reason as
# sed.bin above.
$(BUILD)/nl.bin: $(BINSRC)/nlopt.s $(BINSRC)/nlfmt.s

# cal.s `put`s TWO files: calcalc.s (operand parsing CKYEAR/
# PARSENUM/ACCUM10, plus the Sakamoto day-of-week/leap-year test
# CALCDOW/DIV16) and calmon.s (the renderers PRINTMON/CALPR2/
# BUILDTTL and the year form's quarter painter SLOTBASE/PRINTQTR/
# PRINT22/PRINTQSEP), both split for the same as-window budget --
# cal.s alone measured 20,869 B stripped (resident + liba/stdio.s,
# its own largest put) before calcalc.s, and 19,528 B again after
# the three-column year form landed 2026-09-17. calcalc.s stays the
# charged put at 5,782 B, so calmon.s was sized under it. Same
# reason as sed.bin above.
$(BUILD)/cal.bin: $(BINSRC)/calcalc.s $(BINSRC)/calmon.s

# od.s `put`s odrow.s (the dump engine PRROWHEX/PRROWOCT/PRROWCHR/
# PRCHRDOT/PRHEX4/PROCT3/PRODIG, the buffered byte source GETBYTE/
# REFILL and the -j/-N operand parser OD_PARSENUM/OD_MUL10ADD),
# split for the same as-window budget -- od.s alone measured
# 17,299 B stripped (resident + liba/stdio.s, its own largest put)
# once -j/-N landed, 1,173 over the 16,128-byte window. Same reason
# as sed.bin above.
$(BUILD)/od.bin: $(BINSRC)/odrow.s $(BINSRC)/odtype.s

# tail.s `put`s tailin.s (the input and accumulation layer MUL10ADD/
# BUMPCNT/RDLINE/GETBYTE/REFILL), split for the same as-window
# budget -- tail.s alone measured 17,298 B stripped (resident +
# liba/stdio.s, its own largest put) once -c landed, 1,172 over the
# 16,128-byte window. Same reason as sed.bin above.
$(BUILD)/tail.bin: $(BINSRC)/tailin.s

# strings.s `put`s strfmt.s (the -t offset formatters PRHEXV/
# PROCTV), split for the same as-window budget -- strings.s
# alone measured 16,739 B stripped (resident + liba/stdio.s, its
# own largest put), 611 B over the 16,128-byte window. Same
# reason as sed.bin above.
$(BUILD)/strings.bin: $(BINSRC)/strfmt.s

# nohup.s `put`s nohupfd.s (the NOHUP.OUT redirection package:
# NH_ISTTY/NH_APPOPEN/NH_HOMEPTH/NH_FDADD1/NH_FDADD2, plus every
# message string), split for the same as-window budget -- nohup.s
# alone measured 17,800 B stripped (resident + liba/stdio.s, its
# own largest put), 1,674 B over the 16,128-byte window. Same
# reason as sed.bin above.
$(BUILD)/nohup.bin: $(BINSRC)/nohupfd.s

# timeout.s `put`s TWO files: timeoutaux.s (the error-diagnostic
# tail, the tick-sampling package TO_DECODE/SAMPLE/TO_REACHD/
# TO_REACHK, and every option/usage/message string plus PERITAB)
# and timeoutparse.s (TO_PARSEDUR/TO_MUL10/TO_PARSESIG/
# TO_NAMEIS) -- timeout.s alone measured 24,421 B stripped
# (resident + liba/stdio.s, its own largest put), 8,295 B over
# the 16,128-byte window. As with nl.s above, one put file big
# enough to close the gap would itself have become the new
# largest-put term and left the unit over budget again; two
# balanced put files (4,873 B / 5,162 B, both under liba/
# stdio.s's own 5,581 B) instead give 8,905 (resident) + 5,581 =
# 14,486, comfortably under. Same as-window reason as sed.bin
# above.
$(BUILD)/timeout.bin: $(BINSRC)/timeoutaux.s $(BINSRC)/timeoutparse.s
# tsort.s `put`s tsortp.s (the token-parsing engine PARSE/
# SKIPWS/READTOK/LOOKUPADD/NODEPTR/SLOTCMP/SLOTSET/ADDEDGE),
# split for the same as-window budget -- tsort.s alone measured
# 16,435 B stripped, 309 B over the 16,128-byte window. Same
# reason as sed.bin above.
$(BUILD)/tsort.bin: $(BINSRC)/tsortp.s

# pr.s `put`s prparse.s (the +page/option grammar) and prfmt.s
# (the page-rendering engine), split THREE ways for the same
# as-window budget -- pr.s alone measured 26,612 B stripped,
# far over the 16,128-byte window (a single split would only
# have swapped which term is largest, per printf.s's own
# three-way precedent). Same reason as sed.bin above.
$(BUILD)/pr.bin: $(BINSRC)/prparse.s $(BINSRC)/prfmt.s $(BINSRC)/prout.s $(BINSRC)/prcol.s $(BINSRC)/prmrg.s
# split.s `put`s splitpc.s (PARSEDEC/ACCUM10/SHL10/SUFINC/
# OPENPIECE/CLOSEPIECE plus GETBYTE/REFILL and the usage/error
# exits), split for the same as-window budget -- split.s alone
# measured 18,865 B stripped (resident + liba/stdio.s, its own
# largest put), over the 16,128-byte window. Same reason as
# sed.bin above.
$(BUILD)/split.bin: $(BINSRC)/splitpc.s

# csplit.s `put`s csplitrn.s (the NUMBER/regex/repeat argument
# handlers, piece open/close/write, the source-line reader,
# error cleanup and decimal parsing), split for real Merlin's
# 41,215-byte source buffer -- csplit.s links regex.s/regex2.s
# (MANDATORY, the house BRE engine; regex2.s alone is 22,811 B
# stripped and already over the 16,128-byte as-window by itself,
# so csplit.s is pinned in check_dialect.AS_WINDOW_OVER for that
# ceiling, same as grep.s/ed.s/ex.s/sed.s/more.s) and without
# this split measured 43,613 B stripped resident+largest-put,
# over the 41,215-byte real-Merlin buffer too.
$(BUILD)/csplit.bin: $(BINSRC)/csplitrn.s

# join.s `put`s joinio.s (per-side line/field readers), joinout.s
# (record-composition/printing) and joinopt.s (numeric/-o list
# parsing), split for the same as-window budget -- join.s alone
# measured 29,904 B stripped (resident + liba/stdio.s, its own
# largest put), over the 16,128-byte window. Same reason as
# sed.bin above.
$(BUILD)/join.bin: $(BINSRC)/joinio.s $(BINSRC)/joinout.s \
                    $(BINSRC)/joinopt.s

# xargs.s `put`s xargstok.s (tokenizer/-I/PARSEDEC) and
# xargsrun.s (batch/-I invocation engine), split for the same
# as-window budget). Same reason as sed.bin above.
$(BUILD)/xargs.bin: $(BINSRC)/xargstok.s $(BINSRC)/xargsrun.s

# printf.s `put`s printffmt.s/printfnum.s/printfcnv.s (the
# %-directive parser, the numeric parser/formatters and the
# per-conversion handlers/%b engine, split THREE ways for the
# same as-window budget -- see printffmt.s's own header for why
# two pieces were not enough). Same reason as sed.bin above.
$(BUILD)/printf.bin: $(BINSRC)/printffmt.s $(BINSRC)/printfnum.s \
                      $(BINSRC)/printfcnv.s

# uudecode.s `put`s uudecdec.s (the two alphabets, RECON4, the
# header-line scanner) and uudecln.s (the two per-line drivers
# and the line reader), split TWO ways -- both well under any
# existing liba put's own size -- for the same as-window budget.
# Same reason as sed.bin above.
$(BUILD)/uudecode.bin: $(BINSRC)/uudecdec.s $(BINSRC)/uudecln.s

# uuencode.s `put`s uuencln.s (the base64 line driver ENCLINEB and
# the buffered chunk reader READCHNK/GETBYTE/REFILL), split for
# the same as-window budget. Same reason as sed.bin above.
$(BUILD)/uuencode.bin: $(BINSRC)/uuencln.s

# ed.s is a MANIFEST since 2026-08-28 (S9): its body lives in three put
# modules, split for the same source-buffer budget. Same reason as
# sed.bin above -- without this, editing a body module rebuilds nothing
# and every gate runs green against a stale image.
$(BUILD)/ed.bin: $(BINSRC)/edparse.s $(BINSRC)/edbuf.s $(BINSRC)/edfile.s \
                 $(BINSRC)/edfil2.s \
                 $(BINSRC)/edsub2.s \
                 $(BINSRC)/edsubst.s

# ex.s is a MANIFEST too (M1, docs/EX-DESIGN.md sec 5): it reuses ed's own
# put-split modules UNCHANGED and forks only exbuf.s in their place -- so
# ex.bin's dependency list is ed.bin's plus exbuf.s, same staleness reason
# as ed.bin above (edit a shared body module, both rebuild). excmd.s (M2,
# docs/EX-DESIGN.md sec 5.5) added the same way -- ex-only, put last.
$(BUILD)/ex.bin: $(BINSRC)/exbuf.s $(BINSRC)/edparse.s $(BINSRC)/edfile.s \
                 $(BINSRC)/edfil2.s \
                 $(BINSRC)/edsub2.s \
                 $(BINSRC)/edsubst.s \
                 $(BINSRC)/excmd.s \
                 $(BINSRC)/excmd2.s \
                 $(BINSRC)/exname.s

# vi.s (docs/VI-DESIGN.md, birth task): reuses ex.s's own put-split
# modules UNCHANGED, plus its own new ones (viscreen.s/
# vimotion.s/viinsert.s/vicmd.s/visearch.s/viop.s/vicache.s) --
# same staleness reason as ed.bin/ex.bin above.
$(BUILD)/vi.bin: $(BINSRC)/exbuf.s $(BINSRC)/edparse.s $(BINSRC)/edfile.s \
                 $(BINSRC)/edfil2.s \
                 $(BINSRC)/edsub2.s \
                 $(BINSRC)/edsubst.s \
                 $(BINSRC)/excmd.s \
                 $(BINSRC)/excmd2.s \
                 $(BINSRC)/exname.s \
                 $(BINSRC)/viscreen.s \
                 $(BINSRC)/vimotion.s \
                 $(BINSRC)/vipage.s \
                 $(BINSRC)/viinsert.s \
                 $(BINSRC)/vicmd.s \
                 $(BINSRC)/visearch.s \
                 $(BINSRC)/viop.s \
                 $(BINSRC)/viop2.s \
                 $(BINSRC)/virep.s \
                 $(BINSRC)/virg.s \
                 $(BINSRC)/vicache.s

check-userland: $(UTIL_BINS)
	@echo "== userland size table (task #10) =="
	@for f in $(UTIL_BINS); do \
		printf '%-28s %6d bytes\n' "$$f" "$$(wc -c < $$f | tr -d ' ')"; \
	done
	@echo "== \$$FF00 / call-number choke-point enforcement =="
	@# COMMENTS ARE NOT REFERENCES. Merlin comments are a `*` in
	@# column 1 or a `;` after code, and a util's header explaining
	@# WHICH syscalls its liba wrappers reach is documentation, not a
	@# choke-point breach. Before this filter, df.s's own header
	@# sentence "wired (SYS_OPEN/SYS_READ)" failed the build --
	@# the gate policing prose rather than code (2026-08-21).
	@# proshimcr.s is EXEMPT: it is the ProDOS MLI adapter core
	@# (TASKS.md #19), the ProDOS-convention analog of syscalls.s --
	@# a sanctioned second caller-side door that MUST issue jsr
	@# $$FF00 to translate a tenant's MLI calls into maux syscalls.
	@# It is a putbin'd blob at $$E000, not linkable with liba, so
	@# it cannot route through SC_*; it IS the wrapper layer, for
	@# the other calling convention.
	@if grep -rn '\$$FF00' $(BINSRC) 2>/dev/null | grep -v '/proshimcr.s:' | grep -v '/plasmald.s:' | grep -vE ':[0-9]+:\*' | sed 's/;.*$$//' | grep '\$$FF00'; then \
		echo "FAIL: \$$FF00 referenced outside src/liba"; exit 1; \
	fi
	@if grep -rnE '\bSYS_(SPAWN|EXIT|WAIT|OPEN|READ|WRITE|CLOSE|CREAT|UNLINK|READDIR|PIPE|BRK|FORK|PSTAT|CLOCK)\b' $(BINSRC) 2>/dev/null | grep -v '/proshimcr.s:' | grep -v '/plasmald.s:' | grep -vE ':[0-9]+:\*'; then \
		echo "FAIL: raw syscall call-number equate referenced outside src/liba"; exit 1; \
	fi
	@echo "OK: choke point holds -- only src/liba mentions \$$FF00 or SYS_*."

# task #3's own byte-budget gate: src/kernel/ffpage.s (the $FFxx page
# template), `put` into src/test/ffpage.size.s at its real org $FF00, must
# assemble to exactly 256 bytes (docs/MEMMAP.md #3.3).
$(FFPAGESIZEBLK): $(SRC)/test/ffpage.size.s $(SRC)/kernel/ffpage.s | $(BUILD)
	$(MERLIN32) $(SRC)/test/ffpage.size.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FFPAGESIZEBLK) || { echo "missing $(FFPAGESIZEBLK)"; exit 1; }

# task #3's full acceptance image: kernel skeleton (entry.s) + $FFxx
# template (ffpage.s) + fake-process test driver, chain-loaded across
# multiple SmartPort blocks (syscalltest.s's own LOADER section).
$(SYSCALLBLK): $(SRC)/test/syscalltest.s $(SRC)/test/syscalltestb.s $(SRC)/kernel/entry.s $(SRC)/kernel/entry2.s $(SRC)/kernel/ffpage.s $(MEMMAP_ALL) $(SYSCALL_ALL) $(EQU_KERNEL) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/syscalltest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SYSCALLBLK) || { echo "missing $(SYSCALLBLK)"; exit 1; }
	@test -f $(SYSCALLBLK)_Output.txt || { echo "missing $(SYSCALLBLK)_Output.txt"; exit 1; }

$(SYSCALLIMAGE): $(SYSCALLBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(SYSCALLBLK) $(SYSCALLIMAGE) $(IMAGE_BLOCKS)


# ---------------------------------------------------------------------------
# task #4: bank-clone core (src/kernel/bankcopy.s).
# ---------------------------------------------------------------------------
$(BANKCOPYBLK) $(BANKCOPYBLK)_Output.txt: $(SRC)/test/bankcopytest.s $(SRC)/test/bankcopytestb.s $(SRC)/kernel/entry.s $(SRC)/kernel/entry2.s $(SRC)/kernel/bankcopy.s $(MEMMAP_ALL) $(SYSCALL_ALL) $(EQU_KERNEL) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/bankcopytest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(BANKCOPYBLK) || { echo "missing $(BANKCOPYBLK)"; exit 1; }
	@test -f $(BANKCOPYBLK)_Output.txt || { echo "missing $(BANKCOPYBLK)_Output.txt"; exit 1; }

$(BANKCOPYIMAGE): $(BANKCOPYBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(BANKCOPYBLK) $(BANKCOPYIMAGE) $(IMAGE_BLOCKS)


$(WRITELANDBLK): $(SRC)/test/writelanding.s $(MEMMAP_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/test/writelanding.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(WRITELANDBLK) || { echo "missing $(WRITELANDBLK)"; exit 1; }

$(WRITELANDIMAGE): $(WRITELANDBLK) $(SCRIPTS)/build_image.py
	python3 $(SCRIPTS)/build_image.py $(WRITELANDBLK) $(WRITELANDIMAGE) $(IMAGE_BLOCKS)


# task #6's acceptance images. `-v1` (not a plain assemble) so merlin32
# also writes build/<name>.bin_Output.txt -- scripts/check_sched.py's
# ONLY source of the `ds`-placed kernel-global addresses it needs to peek
# (see that script's header for why hardcoding them would be wrong).
$(SCHEDPREEMPTBLK): $(SRC)/test/sched.preempt.s $(SCHED_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/sched.preempt.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SCHEDPREEMPTBLK) || { echo "missing $(SCHEDPREEMPTBLK)"; exit 1; }
	@test -f $(SCHEDPREEMPTBLK)_Output.txt || { echo "missing $(SCHEDPREEMPTBLK)_Output.txt"; exit 1; }

$(SCHEDPREEMPTIMAGE): $(SCHEDPREEMPTBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(SCHEDPREEMPTBLK) $(SCHEDPREEMPTIMAGE) $(IMAGE_BLOCKS)

$(SCHEDCOOPBLK): $(SRC)/test/sched.coop.s $(SCHED_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/sched.coop.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SCHEDCOOPBLK) || { echo "missing $(SCHEDCOOPBLK)"; exit 1; }
	@test -f $(SCHEDCOOPBLK)_Output.txt || { echo "missing $(SCHEDCOOPBLK)_Output.txt"; exit 1; }

$(SCHEDCOOPIMAGE): $(SCHEDCOOPBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(SCHEDCOOPBLK) $(SCHEDCOOPIMAGE) $(IMAGE_BLOCKS)

$(SCHEDWAKEBLK): $(SRC)/test/sched.wake.s $(SCHED_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/sched.wake.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SCHEDWAKEBLK) || { echo "missing $(SCHEDWAKEBLK)"; exit 1; }
	@test -f $(SCHEDWAKEBLK)_Output.txt || { echo "missing $(SCHEDWAKEBLK)_Output.txt"; exit 1; }

$(SCHEDWAKEIMAGE): $(SCHEDWAKEBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(SCHEDWAKEBLK) $(SCHEDWAKEIMAGE) $(IMAGE_BLOCKS)


$(PROCESSBLK) $(PROCESSBLK)_Output.txt: $(PROCESS_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/processtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(PROCESSBLK) || { echo "missing $(PROCESSBLK)"; exit 1; }
	@test -f $(PROCESSBLK)_Output.txt || { echo "missing $(PROCESSBLK)_Output.txt"; exit 1; }

$(PROCESSIMAGE): $(PROCESSBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(PROCESSBLK) $(PROCESSIMAGE) $(IMAGE_BLOCKS)


# fork() (docs/FORK.md, src/kernel/procfork.s). Raw block image, no
# ProDOS: fork needs the bank allocator and a pipe, neither of which
# touches the MLI. Built with `-v1` because scripts/check_fork.py
# recovers PRC_FORK/FRK_CLN_*/SCH_CREATE/KRN_EXIT from merlin32's own
# symbol dump for the cost measurement -- those are `ds`/code addresses
# that shift whenever kernel source size changes, so hardcoding them
# would make the gate lie rather than fail (check_sched.py's rule).
#
# procfork.s is in $(KERNEL_PROC_MODS): since the 2026-08-23 fleet
# wiring EVERY process-bearing manifest PUTs and dispatches it
# (K_DISP_COUNT 8 fleet-wide). FORK_DEPS still names it explicitly:
# this is the acceptance image for fork itself, and that dependency
# should not be implicit in a shared variable.
$(FORKBLK): $(FORK_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/forktest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FORKBLK) || { echo "missing $(FORKBLK)"; exit 1; }
	@test -f $(FORKBLK)_Output.txt || { echo "missing $(FORKBLK)_Output.txt"; exit 1; }

$(FORKIMAGE): $(FORKBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(FORKBLK) $(FORKIMAGE) $(IMAGE_BLOCKS)


# ---------------------------------------------------------------------------
# ARG_MAX byte budget (`make check-argv`): src/test/argvtest.s spawns the
# same argv-verifying child seven times -- at the byte ceiling, one byte
# past it, with the pointer array exactly full, one entry past it, and with
# a single argument longer than the per-arg cap that used to cut it.
#
# docs/LIMITS.md required this gate and named the case that carries it: a
# spawn one byte past ARG_MAX must ERROR, not arrive short. Verified to have
# teeth by running it against the pre-fix kernel -- see docs/LIMITS.md.
# ---------------------------------------------------------------------------
$(ARGVBLK) $(ARGVBLK)_Output.txt: $(ARGV_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/argvtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(ARGVBLK) || { echo "missing $(ARGVBLK)"; exit 1; }
	@test -f $(ARGVBLK)_Output.txt || { echo "missing $(ARGVBLK)_Output.txt"; exit 1; }

$(ARGVIMAGE): $(ARGVBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(ARGVBLK) $(ARGVIMAGE) $(IMAGE_BLOCKS)

check-argv: $(ARGVIMAGE) $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_argv.py $(ARGVIMAGE)

# Spawn fdactions list validation (`make check-fdact`, docs/DUPFD-1.md
# phase K): src/test/fdatest.s spawns lists that are bad in every way the
# kernel now refuses, and scripts/check_fdact.py reads the kernel's own
# cells (free banks, PCBs, OFT refcounts, LZ_WANT) before and after.
$(FDABLK) $(FDABLK)_Output.txt: $(FDA_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/fdatest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FDABLK) || { echo "missing $(FDABLK)"; exit 1; }
	@test -f $(FDABLK)_Output.txt || { echo "missing $(FDABLK)_Output.txt"; exit 1; }

$(FDAIMAGE): $(FDABLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(FDABLK) $(FDAIMAGE) $(IMAGE_BLOCKS)

$(FDAPBLK) $(FDAPBLK)_Output.txt: $(FDAP_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/fdatestp.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FDAPBLK) || { echo "missing $(FDAPBLK)"; exit 1; }
	@test -f $(FDAPBLK)_Output.txt || { echo "missing $(FDAPBLK)_Output.txt"; exit 1; }

$(FDAPIMAGE): $(FDAPBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(FDAPBLK) $(FDAPIMAGE) $(IMAGE_BLOCKS)

# Both spawn twins: the builtin one (positives, bad lists, a final good
# spawn) and the plain one (spawnpl.s: bad lists only, no file to load).
check-fdact: $(FDAIMAGE) $(FDAPIMAGE) $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_fdact.py $(FDAIMAGE)
	python3 $(SCRIPTS)/check_fdact.py $(FDAPIMAGE) --plain

# ---------------------------------------------------------------------------
# /dev/ttya0 -- the Super Serial Card's 6551 ACIA (`make check-ser`,
# src/kernel/ser.s, docs/TASKS.md slice 2). src/test/sertest.s: PID 1 runs
# directly (no spawn), needs a REAL tick source for the poll hook
# (src/kernel/ser.s SER_POLL, invoked from TTY_TICK), so it PUTs
# mouse.s/timer.s and calls TIMER_PROBE like playtest.s does -- unlike
# argvtest's/shtest's NOIRQ shortcut. Fast-backend only: scripts/
# check_ser.py resets with {"ssc": true, "clock": false} (the SSC and the
# Timemaster clock both default to slot 2 -- see that script's header).
# ---------------------------------------------------------------------------
SERBLK           := $(BUILD)/sertest.bin
SERIMAGE         := $(BUILD)/sertest.po
SER_DEPS         := $(SRC)/test/sertest.s $(SRC)/test/sertestb.s \
                     $(SRC)/kernel/mouse.s $(SRC)/kernel/timer.s \
                     $(KERNEL_PROC_MODS)

$(SERBLK) $(SERBLK)_Output.txt: $(SER_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/sertest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SERBLK) || { echo "missing $(SERBLK)"; exit 1; }
	@test -f $(SERBLK)_Output.txt || { echo "missing $(SERBLK)_Output.txt"; exit 1; }

$(SERIMAGE): $(SERBLK) $(SCRIPTS)/build_multiblock_image.py
	python3 $(SCRIPTS)/build_multiblock_image.py $(SERBLK) $(SERIMAGE) $(IMAGE_BLOCKS)




# ---------------------------------------------------------------------------
# THE SECOND RIG (docs/MAME.md): boot maux under MAME -- an independently
# written emulator -- from an AppleIISd block device, with RamWorks III,
# UltraTerm and Mockingboard models that share no code with verilogapple.
# `vendor-mame-roms` assembles the romsets (mostly byte-identical renames
# of dumps verilogapple already carries; two pinned downloads).
# check-mame is NOT in CHECK_ALL_TARGETS: it needs `brew install mame`.
# Run it whenever a change touches banking, the console, timers, or the
# spawn path -- it has already caught three real kernel bugs that every
# verilogapple gate missed (see docs/MAME.md "What the second rig found").
# ---------------------------------------------------------------------------
vendor-mame-roms:
	python3 $(SCRIPTS)/vendor_mame_roms.py

# The romsets are a BUILD PRODUCT of the provisioned verilogapple ROM tree
# (which carries pal_u4_v3.jed since KFIX12) plus four pinned downloads,
# so the two gates that boot MAME depend on them instead of on a hand
# step: `make check-release-image` on a clean test-tier tree builds them.
# votrsc01a.zip is the last romset vendor_mame_roms.py writes, so its
# presence means the run finished; the script itself is the other
# prerequisite, so an edit to the recipe rebuilds. Not bootstrap-deps:
# vendor/ is the working tree's cache (like vendor-prodos), not
# DEPS_ROOT, and the downloads are the same class as vendor-prodos's.
MAMEROMS_DONE := vendor/mameroms/votrsc01a.zip
$(MAMEROMS_DONE): $(SCRIPTS)/vendor_mame_roms.py
	python3 $(SCRIPTS)/vendor_mame_roms.py


$(FILECHILDBIN): $(SRC)/test/filechild.s $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/test/filechild.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FILECHILDBIN) || { echo "missing $(FILECHILDBIN)"; exit 1; }

$(FILEPROCESSBLK): $(FILEPROCESS_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/fileproctest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FILEPROCESSBLK) || { echo "missing $(FILEPROCESSBLK)"; exit 1; }
	@test -f $(FILEPROCESSBLK)_Output.txt || { echo "missing $(FILEPROCESSBLK)_Output.txt"; exit 1; }



# Sticky-image spawn cache gate (task #15, docs/STICKY.md section 6):
# cold spawn vs warm spawn cycle counts, then an on-disk rewrite that
# must NOT run stale.
$(STICKYBLK): $(STICKY_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/stickytest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(STICKYBLK) || { echo "missing $(STICKYBLK)"; exit 1; }
	@test -f $(STICKYBLK)_Output.txt || { echo "missing $(STICKYBLK)_Output.txt"; exit 1; }



# ADDITIVE cat read-side gate (the recommended read-side gate, this
# round's sh task): src/test/catreadtest.s + scripts/build_catread_image.py
# + scripts/check_catread.py. Boots cat.bin with fd 0 redirected from one
# ProDOS file and fd 1 to another, asserts byte-identical content -- proves
# userland SC_READ end-to-end. Does NOT touch fileprocess-image/
# check-fileprocess (task brief: "do not edit the existing gate").
# ---------------------------------------------------------------------------
CATREADBLK       := $(BUILD)/MAUXCATREAD.SYSTEM
CATREADIMAGE     := $(BUILD)/catread.po
CATREAD_DEPS     := $(SRC)/test/catreadtest.s $(SRC)/test/catreadtestb.s \
                     $(KERNEL_PROC_MODS)

$(CATREADBLK) $(CATREADBLK)_Output.txt: $(CATREAD_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/catreadtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(CATREADBLK) || { echo "missing $(CATREADBLK)"; exit 1; }
	@test -f $(CATREADBLK)_Output.txt || { echo "missing $(CATREADBLK)_Output.txt"; exit 1; }



# K2 pipe-wrap gate (docs/PROCIO.md sec 6, "WATCH THE WRAP"): a pipe
# transfer deliberately constructed to cross the 256B ring's wrap boundary
# on both the write side and the read side, asserted byte-exact. Also this
# task's before/after cycle measurement for K2's bulk BankCopy path. Boots
# with no userland binaries or ProDOS data files -- only SYS_PIPE/
# SYS_READ/SYS_WRITE/SYS_CLOSE. Same shape as the catread gate above.
# ---------------------------------------------------------------------------
PIPEWRAPBLK      := $(BUILD)/MAUXPIPEWRAP.SYSTEM
PIPEWRAPIMAGE    := $(BUILD)/pipewrap.po
PIPEWRAP_DEPS    := $(SRC)/test/pipewraptest.s $(SRC)/test/pipewraptestb.s \
                     $(KERNEL_PROC_MODS)

$(PIPEWRAPBLK) $(PIPEWRAPBLK)_Output.txt: $(PIPEWRAP_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/pipewraptest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(PIPEWRAPBLK) || { echo "missing $(PIPEWRAPBLK)"; exit 1; }
	@test -f $(PIPEWRAPBLK)_Output.txt || { echo "missing $(PIPEWRAPBLK)_Output.txt"; exit 1; }



# Buffered-streams gate (docs/PROCIO.md sec 6, gates (c) and (d)):
# src/test/bufiotest.s + bufiotestb.s + src/test/bufwriter.s +
# scripts/build_bufio_image.py + scripts/check_bufio.py. Gate (a)
# (byte-identical output with/without buffering) and gate (b) (a
# line-buffered prompt appears before the read that follows it) are
# NOT new gates here -- they are check-ls/check-catread/check-sh's own
# existing byte-exact assertions (a) and check-play's own "wait for
# the '$ ' prompt on screen before any keystroke is sent" assertion
# (b), which this task's PUTC/GETC changes must keep passing
# unmodified. This gate covers only the two NEW behaviors those
# existing gates cannot exercise: EXIT flushing bytes that never hit
# an in-band flush trigger, and the sec 5 LC-bank-1 invariant.
BUFIOBLK      := $(BUILD)/MAUXBUFIO.SYSTEM
BUFIOIMAGE    := $(BUILD)/bufio.po
BUFIO_DEPS    := $(SRC)/test/bufiotest.s $(SRC)/test/bufiotestb.s \
                  $(KERNEL_PROC_MODS)

$(BUFIOBLK) $(BUFIOBLK)_Output.txt: $(BUFIO_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/bufiotest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(BUFIOBLK) || { echo "missing $(BUFIOBLK)"; exit 1; }
	@test -f $(BUFIOBLK)_Output.txt || { echo "missing $(BUFIOBLK)_Output.txt"; exit 1; }

$(BUILD)/bufwriter.bin: $(SRC)/test/bufwriter.s $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/test/bufwriter.s

# ---------------------------------------------------------------------------
# seek-family gate (`make check-seek`): docs/FLEET.md "`>>` and the seek
# family". src/test/seekwr.s (a real liba-linked program exercising
# SEEK_SET/SEEK_CUR/SEEK_END, each landing independently re-verified with a
# raw GET_MARK) + src/test/seektest.s/seektestb.s (the raw kernel harness
# that spawns it AND spawns real sh over a staged script to prove `echo a >
# F` then `echo b >> F` leaves F holding both, in order) +
# scripts/build_seek_image.py + scripts/check_seek.py.
# ---------------------------------------------------------------------------
$(BUILD)/seekwr.bin: $(SRC)/test/seekwr.s $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/test/seekwr.s

SEEKTESTBLK      := $(BUILD)/MAUXSEEK.SYSTEM
SEEKIMAGE        := $(BUILD)/seek.po
SEEKTEST_DEPS    := $(SRC)/test/seektest.s $(SRC)/test/seektestb.s \
                     $(KERNEL_PROC_MODS)

$(SEEKTESTBLK) $(SEEKTESTBLK)_Output.txt: $(SEEKTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/seektest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SEEKTESTBLK) || { echo "missing $(SEEKTESTBLK)"; exit 1; }
	@test -f $(SEEKTESTBLK)_Output.txt || { echo "missing $(SEEKTESTBLK)_Output.txt"; exit 1; }

seek-image: $(SEEKTESTBLK) $(BUILD)/seekwr.bin $(UTIL_BINS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_seek_image.py

check-seek: seek-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_seek.py $(SEEKIMAGE)

bufio-image: $(BUFIOBLK) $(BUILD)/bufwriter.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_bufio_image.py

check-bufio: bufio-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_bufio.py $(BUFIOIMAGE)

# ---------------------------------------------------------------------------
# ls acceptance gate (`make check-ls`): src/test/lstest.s +
# scripts/build_ls_image.py + scripts/check_ls.py. Boots ls.bin from disk
# FOUR times with fd 1 (and, for the nonexistent-path run, fd 2) redirected
# to real ProDOS files -- a plain listing, a `-l` directory listing, a `-l`
# single-file GET_FILE_INFO stat, and a nonexistent-path error -- and
# asserts byte-exact output against scripts/build_ls_image.py's
# compute_expected(), which re-reads the actual built image (blocks_used,
# GS/OS case flags, and the three date behaviors all come from real
# on-disk bytes, not hand-computed). Same shape as the catread gate above.
LSTESTBLK        := $(BUILD)/MAUXLSTEST.SYSTEM
LSIMAGE          := $(BUILD)/ls.po
LSTEST_DEPS      := $(SRC)/test/lstest.s $(SRC)/test/lstestb.s \
                     $(KERNEL_PROC_MODS)

$(LSTESTBLK) $(LSTESTBLK)_Output.txt: $(LSTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/lstest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(LSTESTBLK) || { echo "missing $(LSTESTBLK)"; exit 1; }
	@test -f $(LSTESTBLK)_Output.txt || { echo "missing $(LSTESTBLK)_Output.txt"; exit 1; }

ls-image: $(LSTESTBLK) $(BUILD)/ls.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_ls_image.py

check-ls: ls-image play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ls.py $(LSIMAGE)

# ---------------------------------------------------------------------------
# sh integration gate (`make check-sh`): src/test/shtest.s +
# scripts/build_sh_image.py + scripts/check_sh.py. Boots sh.bin from disk
# with fd 0 redirected from a staged script file, exercises redirection
# AND a pipeline end to end (docs/SH-DESIGN.md).
# ---------------------------------------------------------------------------
SHTESTBLK        := $(BUILD)/MAUXSH.SYSTEM
SHIMAGE          := $(BUILD)/sh.po
SHTEST_DEPS      := $(SRC)/test/shtest.s $(SRC)/test/shtestb.s \
                     $(KERNEL_PROC_MODS)

# `-v1` (not a plain assemble) so merlin32 also writes
# build/MAUXSH.SYSTEM_Output.txt. scripts/check_textaudit.py reads
# LZ_RETAIN and the lazy-free slot tables out of it: every one of those
# is `ds`- or PC-placed and moves whenever kernel source size changes,
# so hardcoding them would poison the audit silently (the hygiene rule
# in learning:01M0M9R7RT22JEPP2R0Y6J9MBX). check-sh/check-v1-system/
# check-textaudit all share this one .SYSTEM binary, so the dump is
# produced once here rather than by a fourth image rule.
#
# THE DUMP IS A TARGET, NOT A SIDE EFFECT, and that is load-bearing.
# It was written as a side effect of the .SYSTEM rule, so make had no
# reason to regenerate it while the .SYSTEM was up to date -- and the
# first full sweep after this gate landed read a THREE-DAY-OLD dump
# that predated lazy free. It failed loudly only by luck: LZ_RETAIN
# did not exist at all on 2026-08-19, so the lookup raised. Had the
# symbol merely MOVED, the audit would have stopped at a stale
# address and reported a silent verdict about nothing. Naming the
# dump as its own target against the same prerequisites is what makes
# "older than the sources" mean "rebuild" (make treats a multi-target
# non-pattern rule as one rule per target, so either being stale runs
# the assemble).
$(SHTESTBLK) $(SHTESTBLK)_Output.txt: $(SHTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/shtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SHTESTBLK) || { echo "missing $(SHTESTBLK)"; exit 1; }
	@test -f $(SHTESTBLK)_Output.txt || { echo "missing $(SHTESTBLK)_Output.txt"; exit 1; }

sh-image: $(SHTESTBLK) $(UTIL_BINS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_sh_image.py

check-sh: sh-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_sh.py $(SHIMAGE)

# ---------------------------------------------------------------------------
# ENVIRONMENT gate (`make check-env`, docs/SYSCALL.md item 13c):
# src/test/envtest.s + envtestb.s + src/test/envprobe.s (the getenv-using
# child) + scripts/build_env_image.py + scripts/check_env.py. Same "sh runs
# a script, results read back off the disk image byte-exact" mechanism as
# check-sh, and SEPARATE from it for the reason check-shlang is: check-sh
# is the fixed redirect/pipe baseline, this is the environment's own proof
# and grows with the environment (`unset` and `env` next, if ever).
#
# ONE case carries it, and both halves are in the same file: an EXPORTED
# variable reaches a spawned child's getenv and an UNEXPORTED one does not.
# The second half is what a partial implementation passes -- see
# build_env_image.py's own header for the script and every expectation.
# ---------------------------------------------------------------------------
ENVTESTBLK       := $(BUILD)/MAUXENV.SYSTEM
ENVIMAGE         := $(BUILD)/env.po
ENVTEST_DEPS     := $(SRC)/test/envtest.s $(SRC)/test/envtestb.s \
                     $(KERNEL_PROC_MODS)

$(ENVTESTBLK) $(ENVTESTBLK)_Output.txt: $(ENVTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/envtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(ENVTESTBLK) || { echo "missing $(ENVTESTBLK)"; exit 1; }
	@test -f $(ENVTESTBLK)_Output.txt || { echo "missing $(ENVTESTBLK)_Output.txt"; exit 1; }

$(BUILD)/envprobe.bin: $(SRC)/test/envprobe.s $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/test/envprobe.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }

env-image: $(ENVTESTBLK) $(BUILD)/sh.bin $(BUILD)/echo.bin \
             $(BUILD)/envprobe.bin $(BUILD)/find.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_env_image.py

check-env: env-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_env.py $(ENVIMAGE)

# ---------------------------------------------------------------------------
# sh LANGUAGE gate (`make check-shlang`): src/test/shlangtest.s +
# scripts/build_shlang_image.py + scripts/check_shlang.py. SEPARATE from
# check-sh (docs/SH-SUBSET.md sec 3, Tier 0) rather than an extension of
# it -- check-sh is the baseline redirect/pipe/builtin integration proof
# and stays a fixed, small reference script; this gate is the LANGUAGE
# proof (`$?`, `;`, `&&`, `||`) and grows with the language (Tier 1/2
# next), which would otherwise keep bloating check-sh's own SCRIPT_TEXT
# and its unrelated EDITED/CATOUT expectations. Same "sh runs a script,
# read results back off the disk" mechanism as check-sh/check-fleet.
# ---------------------------------------------------------------------------
SHLANGTESTBLK    := $(BUILD)/MAUXSHLANG.SYSTEM
SHLANGIMAGE      := $(BUILD)/shlang.po
SHLANGTEST_DEPS  := $(SRC)/test/shlangtest.s $(SRC)/test/shlangtestb.s \
                     $(KERNEL_PROC_MODS)

$(SHLANGTESTBLK) $(SHLANGTESTBLK)_Output.txt: $(SHLANGTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/shlangtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SHLANGTESTBLK) || { echo "missing $(SHLANGTESTBLK)"; exit 1; }
	@test -f $(SHLANGTESTBLK)_Output.txt || { echo "missing $(SHLANGTESTBLK)_Output.txt"; exit 1; }

shlang-image: $(SHLANGTESTBLK) $(UTIL_BINS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_shlang_image.py

check-shlang: shlang-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shlang.py $(SHLANGIMAGE)

# ---------------------------------------------------------------------------
# fleet acceptance gate (`make check-fleet`): src/test/fleettest.s +
# scripts/build_fleet_image.py + scripts/check_fleet.py. Boots the six
# never-before-executed commands (`cmp sort uniq tr od file`) for the first
# time: phase 1 runs a nineteen-line script through `sh` (redirection AND
# `>>` append) and byte-compares every result file straight off the disk
# image; phase 2 spawns `cmp` directly (fd 2 captured) since `sh` cannot
# redirect stderr, docs/FLEET.md's "cheap wins" list.
# ---------------------------------------------------------------------------
FLEETTESTBLK     := $(BUILD)/MAUXFLEET.SYSTEM
FLEETIMAGE       := $(BUILD)/fleet.po
FLEETTEST_DEPS   := $(SRC)/test/fleettest.s $(SRC)/test/fleettestb.s \
                     $(KERNEL_PROC_MODS)

$(FLEETTESTBLK) $(FLEETTESTBLK)_Output.txt: $(FLEETTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/fleettest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FLEETTESTBLK) || { echo "missing $(FLEETTESTBLK)"; exit 1; }
	@test -f $(FLEETTESTBLK)_Output.txt || { echo "missing $(FLEETTESTBLK)_Output.txt"; exit 1; }

fleet-image: $(FLEETTESTBLK) $(UTIL_BINS) $(BUILD)/sleep.bin $(BUILD)/echo.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_fleet_image.py

check-fleet: fleet-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_fleet.py $(FLEETIMAGE)

# TEST_EVAL acceptance gate (`make check-testev`): src/bin/testeval.s,
# the `test`/`[` expression evaluator (docs/SH-SUBSET.md sec 6.3 -- a
# BUILTIN engine, gated on its own, same shape as check-glob's
# GLOBMATCH but needing a live process for -f/-d/-e's SC_GFI, hence the
# fuller kernel-boot harness (src/test/testevtest.s + testevtestb.s).
# 40-case table, glob-test style.
TESTEVBLK        := $(BUILD)/MAUXTESTEV.SYSTEM
TESTEVIMAGE      := $(BUILD)/testev.po
TESTEV_DEPS      := $(SRC)/test/testevtest.s $(SRC)/test/testevtestb.s \
                     $(SRC)/bin/testeval.s \
                     $(LIBA_SRCS) $(KERNEL_PROC_MODS)

$(TESTEVBLK) $(TESTEVBLK)_Output.txt: $(TESTEV_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/testevtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(TESTEVBLK) || { echo "missing $(TESTEVBLK)"; exit 1; }
	@test -f $(TESTEVBLK)_Output.txt || { echo "missing $(TESTEVBLK)_Output.txt"; exit 1; }

testev-image: $(TESTEVBLK)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_testev_image.py

check-testev: testev-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_testev.py $(TESTEVIMAGE)

# tail acceptance gate (`make check-tail`): src/test/tailtest.s +
# scripts/build_tail_image.py + scripts/check_tail.py. Boots tail.bin
# from disk SIX times with fd 1 (and, for the fd-0 run, fd 0 too)
# redirected to real ProDOS files -- default N=10, -3, -20 (more than
# the file has), an empty file, a file whose last line lacks a
# trailing CR, and reading from fd 0 -- and asserts byte-exact output
# against scripts/build_tail_image.py's hand-derived expectations.
# Same shape as the catread/ls gates above.
TAILTESTBLK      := $(BUILD)/MAUXTAIL.SYSTEM
TAILIMAGE        := $(BUILD)/tail.po
TAILTEST_DEPS    := $(SRC)/test/tailtest.s $(SRC)/test/tailtestb.s \
                     $(KERNEL_PROC_MODS)

$(TAILTESTBLK) $(TAILTESTBLK)_Output.txt: $(TAILTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/tailtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(TAILTESTBLK) || { echo "missing $(TAILTESTBLK)"; exit 1; }
	@test -f $(TAILTESTBLK)_Output.txt || { echo "missing $(TAILTESTBLK)_Output.txt"; exit 1; }

tail-image: $(TAILTESTBLK) $(BUILD)/tail.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_tail_image.py

check-tail: tail-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_tail.py $(TAILIMAGE)

# nm acceptance gate (`make check-nm`): src/test/nmtest.s +
# scripts/build_nm_image.py + scripts/check_nm.py. Same shape as check-sh:
# one hardwired parent process spawns `sh` (stdin redirected from a staged
# script) which runs `nm` against REAL REL files (RTLIB/RTMAIN, the exact
# bytes `make check-rel` assembles under real Merlin-8 2.59 -- see
# build_nm_image.py's own header for the byte-level provenance), then the
# result files are read back off the disk image and compared byte-exact
# against expectations hand-derived from those REL files' bytes (docs/
# REL-LIBA-SPIKE.md's format plus nm.s's own header for the dictionary
# byte layout), never by running nm and recording what it prints.
# ---------------------------------------------------------------------------
NMTESTBLK        := $(BUILD)/MAUXNM.SYSTEM
NMIMAGE          := $(BUILD)/nm.po
NMTEST_DEPS      := $(SRC)/test/nmtest.s $(SRC)/test/nmtestb.s \
                     $(KERNEL_PROC_MODS)


# `-v1` (not a plain assemble) so merlin32 also writes
# build/MAUXNM.SYSTEM_Output.txt -- scripts/check_nm.py's poison-
# between-runs gate (docs/STICKY.md sec 25/28/37) reads LZ_RETAIN and
# the lazy-free slot tables out of it via scripts/textaudit.py, the
# same "the dump is a TARGET, not a side effect" reasoning as
# $(SHTESTBLK)'s own rule above: a stale dump would read a symbol at
# the WRONG address rather than fail, so this co-target keeps it
# rebuilt exactly when nmtest.s's own dependencies change.
#
# THE CO-TARGET DOES NOT PROTECT AN ALREADY-BUILT TREE, measured
# 2026-08-23 at merge. When a rule GAINS `-v1`, an existing
# build/<name>.SYSTEM is still newer than its sources, so
# `make build/<name>.SYSTEM` considers it up to date, skips the recipe,
# and the dump is never written -- the `test -f` guards below only fire
# if the recipe RUNS. check-nm and check-comm were the only two reds in
# a 56-gate sweep for exactly this reason, and the traceback was a bare
# FileNotFoundError rather than anything naming the cause. A fresh
# clone is fine; an incrementally-built tree is not. If you add `-v1`
# to a rule, delete that rule's existing output once so the co-target
# is produced.
$(NMTESTBLK) $(NMTESTBLK)_Output.txt: $(NMTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/nmtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(NMTESTBLK) || { echo "missing $(NMTESTBLK)"; exit 1; }
	@test -f $(NMTESTBLK)_Output.txt || { echo "missing $(NMTESTBLK)_Output.txt"; exit 1; }

nm-image: $(NMTESTBLK) $(BUILD)/sh.bin $(BUILD)/nm.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_nm_image.py

check-nm: nm-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_nm.py $(NMIMAGE)

# find acceptance gate (`make check-find`): src/test/findtest.s +
# scripts/build_find_image.py + scripts/check_find.py. Boots find.bin from
# disk SIX times with stdout (and, for the depth-overflow run, stderr)
# redirected to real ProDOS files -- a plain walk, a -name filter, -type d,
# -type f, an -exec running real `cat`, and a depth-limit overflow -- and
# asserts byte-exact output against scripts/build_find_image.py's
# compute_expected(), which derives every expectation from the REAL on-disk
# directory structure (a2til's own scandir(), the same slot-order algorithm
# src/liba/readdir.s implements) rather than from running find.bin. Same
# shape as the ls gate above.
FINDTESTBLK      := $(BUILD)/MAUXFINDTEST.SYSTEM
FINDIMAGE        := $(BUILD)/find.po
FINDTEST_DEPS    := $(SRC)/test/findtest.s $(SRC)/test/findtestb.s \
                     $(SRC)/test/findtestc.s \
                     $(KERNEL_PROC_MODS)

$(FINDTESTBLK) $(FINDTESTBLK)_Output.txt: $(FINDTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/findtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(FINDTESTBLK) || { echo "missing $(FINDTESTBLK)"; exit 1; }
	@test -f $(FINDTESTBLK)_Output.txt || { echo "missing $(FINDTESTBLK)_Output.txt"; exit 1; }

find-image: $(FINDTESTBLK) $(BUILD)/find.bin $(BUILD)/cat.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_find_image.py

check-find: find-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_find.py $(FINDIMAGE)

# sed acceptance gate (`make check-sed`): src/test/sedtest.s +
# scripts/build_sed_image.py + scripts/check_sed.py. Boots sed.bin from
# disk NINE times, stdout AND stderr redirected every run. Runs 1-7 are
# HOST-DIFFERENTIAL (docs/E2E.md sec 4 stage 1): the expected bytes come
# from running the identical POSIX-portable scripts through the host's
# /usr/bin/sed on the identical input and translating text conventions
# -- no authored expectations, and NEVER a recorded maux run. Runs 8-9
# are maux's own error paths (open failure; the loud refusal of an
# out-of-scope command), each a NAMED entry in check_sed.DIVERGENCE.
SEDTESTBLK       := $(BUILD)/MAUXSEDTEST.SYSTEM
SEDIMAGE         := $(BUILD)/sed.po
SEDTEST_DEPS     := $(SRC)/test/sedtest.s $(SRC)/test/sedtestb.s \
                     $(KERNEL_PROC_MODS)

$(SEDTESTBLK) $(SEDTESTBLK)_Output.txt: $(SEDTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/sedtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SEDTESTBLK) || { echo "missing $(SEDTESTBLK)"; exit 1; }
	@test -f $(SEDTESTBLK)_Output.txt || { echo "missing $(SEDTESTBLK)_Output.txt"; exit 1; }

sed-image: $(SEDTESTBLK) $(BUILD)/sed.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_sed_image.py

check-sed: sed-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_sed.py $(SEDIMAGE)

# `diff` acceptance gate (`make check-diff`): src/bin/diff.s (LCS
# dynamic-programming line diff, docs/FLEET.md 4(a) -- "the only
# MISSING-nothing-blocks item that's genuinely hard"). Boots the kernel
# + a hardwired parent process (src/test/difftest.s + difftestb.s) that
# spawns `diff` directly ten times (the required contract shapes, plus
# an overflow trigger and a -e case), fd 1/2 dup'd to a captured output
# file each -- fleettestb.s's own direct-spawn/fd-dup technique, table-
# driven since there are ten of them. One more spawn (`ed`, stdin from
# a hand-built script) proves the diff -e | ed round trip.
# ---------------------------------------------------------------------------
DIFFTESTBLK      := $(BUILD)/MAUXDIFFTEST.SYSTEM
DIFFIMAGE        := $(BUILD)/difftest.po
DIFFTEST_DEPS    := $(SRC)/test/difftest.s $(SRC)/test/difftestb.s \
                     $(INC)/mli.equ $(KERNEL_PROC_MODS)

$(DIFFTESTBLK) $(DIFFTESTBLK)_Output.txt: $(DIFFTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/difftest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(DIFFTESTBLK) || { echo "missing $(DIFFTESTBLK)"; exit 1; }
	@test -f $(DIFFTESTBLK)_Output.txt || { echo "missing $(DIFFTESTBLK)_Output.txt"; exit 1; }

diff-image: $(DIFFTESTBLK) $(BUILD)/diff.bin $(BUILD)/ed.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_diff_image.py

check-diff: diff-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_diff.py $(DIFFIMAGE)

# `expr` acceptance gate (`make check-expr`): src/bin/expr.s (the
# real spawnable binary) + src/bin/expr.eval.s (the engine, no I/O
# of its own -- same split as testeval.s) + src/test/exprtest.s /
# exprtestb.s. A hand-derived 37-row case table calls
# EXPR_EVAL/EXPR_EXITCD directly, same shape as check-testev's own
# gate against TEST_EVAL: every operator, both outcomes per
# comparison, precedence both directions, overflow, division/modulo
# by zero. NOT covered: expr.bin's own top-level argv/print/exit
# glue -- a direct-spawn phase for that was attempted and dropped;
# see exprtest.s's header.
EXPRTESTBLK      := $(BUILD)/MAUXEXPR.SYSTEM
EXPRIMAGE        := $(BUILD)/expr.po
EXPRTEST_DEPS    := $(SRC)/test/exprtest.s $(SRC)/test/exprtestb.s \
                     $(SRC)/bin/expr.s $(SRC)/bin/expr.eval.s \
                     $(SRC)/bin/expr.ops.s $(SRC)/bin/expr.match.s \
                     $(LIBA_SRCS) $(KERNEL_PROC_MODS)

$(EXPRTESTBLK) $(EXPRTESTBLK)_Output.txt: $(EXPRTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/exprtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(EXPRTESTBLK) || { echo "missing $(EXPRTESTBLK)"; exit 1; }
	@test -f $(EXPRTESTBLK)_Output.txt || { echo "missing $(EXPRTESTBLK)_Output.txt"; exit 1; }

$(BUILD)/exprcases.bin: $(SRC)/test/exprcases.s | $(BUILD)
	$(MERLIN32) $(SRC)/test/exprcases.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }

expr-image: $(EXPRTESTBLK) $(BUILD)/expr.bin $(BUILD)/exprcases.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_expr_image.py

check-expr: expr-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_expr.py $(EXPRIMAGE)

# du acceptance gate (`make check-du`): src/test/dutest.s +
# scripts/build_du_image.py + scripts/check_du.py. Boots du.bin from disk
# FIVE times with stdout (and, for the bad-path run, stderr) redirected to
# real ProDOS files -- a plain walk, -s, -a, a single-file argument, and a
# nonexistent-path-then-valid-path run -- and asserts byte-exact output
# against scripts/build_du_image.py's compute_expected(), which derives
# every block-count expectation from the REAL blocks_used a2til's own
# ProDOS allocator gave each staged file/directory (same technique
# build_ls_image.py's own compute_expected() already uses for the sapling
# blocks_used trap), not from running du.bin. Same shape as the find gate
# above.
DUTESTBLK        := $(BUILD)/MAUXDUTEST.SYSTEM
DUIMAGE          := $(BUILD)/du.po
DUTEST_DEPS      := $(SRC)/test/dutest.s $(SRC)/test/dutestb.s \
                     $(KERNEL_PROC_MODS)

$(DUTESTBLK) $(DUTESTBLK)_Output.txt: $(DUTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/dutest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(DUTESTBLK) || { echo "missing $(DUTESTBLK)"; exit 1; }
	@test -f $(DUTESTBLK)_Output.txt || { echo "missing $(DUTESTBLK)_Output.txt"; exit 1; }

du-image: $(DUTESTBLK) $(BUILD)/du.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_du_image.py

check-du: du-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_du.py $(DUIMAGE)

# tee/comm acceptance gate (`make check-comm`): src/test/commtest.s +
# scripts/build_comm_image.py + scripts/check_comm.py. ONE gate for both
# tools (not two near-identical harnesses) -- same "sh runs a script,
# results read back off the disk image byte-exact" mechanism as
# check-shlang/check-fleet, modeled directly on check-fleet's own.
# ---------------------------------------------------------------------------
COMMTESTBLK      := $(BUILD)/MAUXCOMM.SYSTEM
COMMIMAGE        := $(BUILD)/comm.po
COMMTEST_DEPS    := $(SRC)/test/commtest.s $(SRC)/test/commtestb.s \
                     $(KERNEL_PROC_MODS)


# `-v1` (not a plain assemble), same reason as $(NMTESTBLK)'s own rule
# above: scripts/check_comm.py's poison-between-runs gate reads
# LZ_RETAIN and the lazy-free slot tables via scripts/textaudit.py, and
# the dump must be a TARGET (rebuilt whenever commtest.s's own
# dependencies change), not a side effect that can go stale.
$(COMMTESTBLK) $(COMMTESTBLK)_Output.txt: $(COMMTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/commtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(COMMTESTBLK) || { echo "missing $(COMMTESTBLK)"; exit 1; }
	@test -f $(COMMTESTBLK)_Output.txt || { echo "missing $(COMMTESTBLK)_Output.txt"; exit 1; }

comm-image: $(COMMTESTBLK) $(BUILD)/sh.bin $(BUILD)/cat.bin \
                     $(BUILD)/wc.bin $(BUILD)/tee.bin $(BUILD)/comm.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_comm_image.py

check-comm: comm-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_comm.py $(COMMIMAGE)

# sum/date acceptance gate (`make check-sumdate`): src/test/
# sumdatetest.s + sumdatetestb.s + scripts/build_sumdate_image.py +
# scripts/check_sumdate.py. `sum` (V6-style checksum+blocks) spawned
# once on an empty/one-byte/block-crossing file trio; `date` spawned
# with its ProDOS Global Page reading captured via the kernel's own
# SYS_CLOCK (task 2026-08-21, the ONE kernel addition this pair
# needed) and cross-checked against a raw peek of $BF90-$BF93 --
# checked twice, once with the emulator's clock card present and once
# without, so both of `date`'s paths run.
# ---------------------------------------------------------------------------
SUMDATETESTBLK   := $(BUILD)/MAUXSUMDT.SYSTEM
SUMDATEIMAGE     := $(BUILD)/sumdate.po
SUMDATETEST_DEPS := $(SRC)/test/sumdatetest.s $(SRC)/test/sumdatetestb.s \
                     $(KERNEL_PROC_MODS)

$(SUMDATETESTBLK) $(SUMDATETESTBLK)_Output.txt: $(SUMDATETEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/sumdatetest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(SUMDATETESTBLK) || { echo "missing $(SUMDATETESTBLK)"; exit 1; }
	@test -f $(SUMDATETESTBLK)_Output.txt || { echo "missing $(SUMDATETESTBLK)_Output.txt"; exit 1; }

sumdate-image: $(SUMDATETESTBLK) $(BUILD)/sum.bin $(BUILD)/date.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_sumdate_image.py

check-sumdate: sumdate-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_sumdate.py $(SUMDATEIMAGE)

# chmod/df acceptance gate (`make check-chmod`): src/test/chmodtest.s +
# scripts/build_chmod_image.py + scripts/check_chmod.py. Same shape as
# check-fleet -- phase 1 runs `sh` (stdin redirected from a staged script)
# through CHMOD's lock/unlock idiom and DF's two argument forms,
# redirecting DF's stdout to files read back byte-exact; phase 2 spawns
# `rm` DIRECTLY against the still-locked file (exit status captured) to
# prove a lock actually resists DESTROY. The read-modify-write proof
# (type/aux_type/dates untouched across a lock+unlock round trip) is
# checked entirely host-side, straight off the built .po image, by
# scripts/check_chmod.py -- no on-device GET_FILE_INFO peeking needed.
# ---------------------------------------------------------------------------
CHMODTESTBLK     := $(BUILD)/MAUXCHMOD.SYSTEM
CHMODIMAGE       := $(BUILD)/chmod.po
CHMODTEST_DEPS   := $(SRC)/test/chmodtest.s $(SRC)/test/chmodtestb.s \
                     $(KERNEL_PROC_MODS)

$(CHMODTESTBLK) $(CHMODTESTBLK)_Output.txt: $(CHMODTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/chmodtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(CHMODTESTBLK) || { echo "missing $(CHMODTESTBLK)"; exit 1; }
	@test -f $(CHMODTESTBLK)_Output.txt || { echo "missing $(CHMODTESTBLK)_Output.txt"; exit 1; }

chmod-image: $(CHMODTESTBLK) $(UTIL_BINS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_chmod_image.py

check-chmod: chmod-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_chmod.py $(CHMODIMAGE)

# ---------------------------------------------------------------------------
# RUNTIME writable-text audit (`make check-textaudit`, docs/STICKY.md
# sec 28): run EVERY spawnable binary in src/bin under maux on real
# work, stop the kernel on its own retire path (LZ_RETAIN) at each
# process exit, and diff the dying bank's image against the .bin on
# disk. Lazy free (sec 27) reuses a retained bank WITHOUT recopying the
# text, so a program that rewrites its own image runs its second
# invocation on its leftovers -- `as` does, and until this gate nothing
# had looked at the other thirty-three.
#
# Each program is ALSO run twice with byte-identical arguments so the
# second run is served warm out of the first run's bank, and the two
# outputs are compared: that is what turns "wrote its own text" into
# "and broke because of it". It is how `ld` was caught.
#
# FOUR images (scripts/build_textaudit_image.py), because the 280-block
# carrier cannot hold 126KB of binaries plus two output files per case;
# they reuse $(SHTESTBLK) verbatim, the way v1-system-image already
# does, so this gate adds no assembly.
#
# `ld` is NOT in $(UTIL_BINS) (it is not in UTILS) -- named explicitly.

textaudit-image: $(SHTESTBLK) $(UTIL_BINS) $(BUILD)/ld.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_textaudit_image.py

check-textaudit: textaudit-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_textaudit.py

# ---------------------------------------------------------------------------
# `sh`'s WARM-RESPAWN gate (`make check-shwarm`, docs/STICKY.md sec 32):
# scripts/build_shwarm_image.py + scripts/check_shwarm.py, reusing
# $(SHTESTBLK) verbatim the way textaudit-image does -- no new assembly.
#
# WHY IT IS A GATE OF ITS OWN rather than another check-textaudit group.
# sec 29 gave `sh` the verdict DIRTY-TAIL with NO repeat pair, because
# nothing in the tree spawned `sh` twice in one boot: it is the login
# shell. This gate arranges the second one (`sh` spawns `sh`; the outer
# shell stays live, so the two NESTED shells are the pair), and it
# POISONS -- the arena AND `sh`'s surviving emitted scratch cells --
# which check-textaudit does not do for any of its 23 converted
# programs. Both halves are this gate's subject; folding them into a
# fleet-wide audit would hide them.
# ---------------------------------------------------------------------------
SHWARMIMAGE      := $(BUILD)/shwarm.po

shwarm-image: $(SHTESTBLK) $(BUILD)/sh.bin $(BUILD)/echo.bin \
                $(BUILD)/cat.bin $(BUILD)/grep.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_shwarm_image.py

check-shwarm: shwarm-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shwarm.py $(SHWARMIMAGE)
# STAGE-1 DIFFERENTIAL HARNESS (`make check-e2e`), docs/E2E.md sec 6 + sec 9.
#
# Every other gate in this file compares maux against an expectation
# somebody wrote down. This one compares it against /usr/bin, on input
# nobody chose by hand -- the oracle is a reference implementation
# (docs/E2E.md sec 4's oracle 1), so there is no author's belief for the
# test to inherit. That is the whole point: the four bugs of 2026-08-23
# were all in programs with passing gates.
#
# TWO targets, deliberately:
#   check-e2e-host  runs entirely on the host and needs no emulator. It
#                   proves the CORPUS: that every comparator accepts a
#                   correct answer and rejects every mutation of one, and
#                   that the divergence ratchet has no uncited entry and
#                   no unexplained citation. `check-string` passed 21/21
#                   against the bug it targeted on 2026-08-22; a
#                   comparator is vacuous until shown otherwise.
#   check-e2e       boots the corpus on the rig and compares for real.
#
# TRANSPORT is `a2til mirror` (README "Mirror"): the generated corpus is
# pushed into /mnt/MAUX/E2E with one `--once --raw` pass and every result is
# pulled back out with another. No write_file loop, no hand-encoded
# high-bit ASCII -- HACKING.md's standing rule, and the reason
# scripts/build_e2e_image.py's header names each mirror feature it uses.
#
# The image is an 800K volume, not the 280-block carrier: MEASURED, the
# carrier has 79 blocks free once the kernel, `sh` and the nine tools are
# staged, and the results do not fit.
# ---------------------------------------------------------------------------
E2ETESTBLK     := $(BUILD)/MAUXE2E.SYSTEM
E2EIMAGE       := $(BUILD)/e2e.po
E2ETEST_DEPS   := $(SRC)/test/e2etest.s $(SRC)/test/e2etestb.s \
                   $(KERNEL_PROC_MODS)
E2E_SCRIPTS    := $(SCRIPTS)/e2e_limits.py $(SCRIPTS)/e2e_ref.py \
                   $(SCRIPTS)/e2e_corpus.py \
                   $(SCRIPTS)/e2e_divergence.py $(SCRIPTS)/e2e_compare.py

$(E2ETESTBLK) $(E2ETESTBLK)_Output.txt: $(E2ETEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/e2etest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(E2ETESTBLK) || { echo "missing $(E2ETESTBLK)"; exit 1; }
	@test -f $(E2ETESTBLK)_Output.txt || { echo "missing $(E2ETESTBLK)_Output.txt"; exit 1; }

# The corpus's boundaries are read out of inc/*.equ and src/bin/*.s
# (docs/E2E.md sec 5), so the image depends on those headers too: raise
# LINEMAX or MLI_IOBUF_CNT and the fixtures change with no edit here.
# sh.s's own put/use chain must be listed, not just sh.s: the image
# stages sh.bin, so editing any of liba or the syscall equates would
# otherwise re-run this gate on a STALE image, green. Caught by
# check-manifests' derived dependency check (S4, STICKY sec 34) the
# first time it ran against this rule.
e2e-image: $(E2ETESTBLK) $(UTIL_BINS) $(E2E_SCRIPTS) $(MEMMAP_ALL) \
             $(SYSCALL_ALL) $(LIBA_SRCS) $(BINSRC)/sh.s $(SH_PUT_MODS) \
             $(BINSRC)/testeval.s
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_e2e_image.py

check-e2e-host: $(E2E_SCRIPTS) $(SCRIPTS)/e2e_selftest.py
	python3 $(SCRIPTS)/e2e_selftest.py

check-e2e: check-e2e-host e2e-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_e2e.py $(E2EIMAGE)

# ---------------------------------------------------------------------------
# T4 write-failure image: one zero-free-block volume plus one locked target.
# The parent process is the same `MAUXE2E.SYSTEM` used by stage 1; only the
# staged files and post-run host-side checker differ.
# ---------------------------------------------------------------------------
WRITEFAILIMAGE   := $(BUILD)/writefail.po
WRITEFAIL_SCRIPTS := $(SCRIPTS)/build_writefail_image.py \
                     $(SCRIPTS)/check_writefail.py

writefail-image: $(E2ETESTBLK) $(UTIL_BINS) $(WRITEFAIL_SCRIPTS) \
                 $(MEMMAP_ALL) $(SYSCALL_ALL) $(LIBA_SRCS) \
                 $(BINSRC)/sh.s $(BINSRC)/testeval.s $(SH_PUT_MODS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_writefail_image.py

check-writefail-host: $(WRITEFAIL_SCRIPTS) $(SCRIPTS)/e2e_compare.py
	python3 $(SCRIPTS)/check_writefail.py --selftest


# ---------------------------------------------------------------------------
# T4 root-directory-growth image: a volume directory staged FULL by the
# classic ProDOS rule (51 entries, 4 blocks) on a volume with 1,435 free
# blocks.  Written for docs/E2E-COVERAGE.md item 7's full-DIRECTORY create
# failure; its first run REFUTED that item -- ProDOS 2.5 grows the chain --
# so the gate pins the capability instead.  Same parent process as stage 1.
# ---------------------------------------------------------------------------
DIRFULLIMAGES   := $(BUILD)/dirfull-24.po $(BUILD)/dirfull-25.po
DIRFULL_SCRIPTS := $(SCRIPTS)/build_dirfull_image.py \
                   $(SCRIPTS)/check_dirfull.py

# BOTH vendored kernels, deliberately: the builder names them itself
# rather than taking PRODOS_KERNEL_BIN, because the whole point is the
# pair. Defaulting to one is what made this look flaky the first time.
dirfull-image: $(E2ETESTBLK) $(UTIL_BINS) $(DIRFULL_SCRIPTS) \
               $(MEMMAP_ALL) $(SYSCALL_ALL) $(LIBA_SRCS) \
               $(BINSRC)/sh.s $(BINSRC)/testeval.s $(SH_PUT_MODS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	@test -f vendor/ProDOS-2.5.bin || { echo "missing vendor/ProDOS-2.5.bin -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_dirfull_image.py

check-dirfull-host: $(DIRFULL_SCRIPTS) $(SCRIPTS)/e2e_compare.py
	python3 $(SCRIPTS)/check_dirfull.py --selftest


# ---------------------------------------------------------------------------
# T4 STAGE-1b: the FILESYSTEM tranche of the e2e differential corpus
# (CONTRACT, scripts/e2e_fsmap.py's header).  Same parent process as
# stage 1 (src/test/e2etest.s / $(E2ETESTBLK), reused UNCHANGED -- this
# tranche writes no 6502 assembly), a DIFFERENT volume (e2efs.po) and a
# different case corpus: ls/find/du/rm/mv/cp/mkdir/chmod/file/ps/pwd/df
# against /mnt/MAUX/RO (immutable) and /mnt/MAUX/MUT/Cnn (per-case, mutable)
# trees staged with the `prodos` module directly, never `a2til mirror`
# (mirror cannot recurse into subdirectories -- see e2e_fsmap.py's
# header).  `E2EFS_SCRIPTS` uses $(wildcard ...) for the five packages
# (E2-E6) that may not exist yet in every worktree -- e2e_fs_corpus.py
# itself skips an absent module with a printed note rather than an
# ImportError, and the Makefile dependency list must not force a rule
# error for a file nobody has written yet either.
#
# check-manifests' derived full-closure dependency check (CHECK 6) is
# satisfied by construction: e2efs-image's non-python dependency list
# (E2ETESTBLK, MEMMAP_ALL, SYSCALL_ALL, LIBA_SRCS, sh.s, testeval.s) is
# COPIED VERBATIM from e2e-image's own already-checked list, because
# both images assemble and stage the exact same 6502 sources
# (src/test/e2etest.s, kernel, liba, sh) -- this tranche adds only
# Python and only more UTIL_BINS (already the full $(UTIL_BINS) set on
# both rules).
# ---------------------------------------------------------------------------
E2EFSIMAGE     := $(BUILD)/e2efs.po
E2EFS_SCRIPTS  := $(SCRIPTS)/e2e_fsmap.py $(SCRIPTS)/e2e_fs_common.py \
                   $(SCRIPTS)/e2e_fs_corpus.py \
                   $(wildcard $(SCRIPTS)/e2e_fs_ls.py) \
                   $(wildcard $(SCRIPTS)/e2e_fs_walk.py) \
                   $(wildcard $(SCRIPTS)/e2e_fs_mutate.py) \
                   $(wildcard $(SCRIPTS)/e2e_fs_meta.py) \
                   $(wildcard $(SCRIPTS)/e2e_invariants.py) \
                   $(wildcard $(SCRIPTS)/e2e_fs_idiom.py)

e2efs-image: $(E2ETESTBLK) $(UTIL_BINS) $(E2E_SCRIPTS) $(E2EFS_SCRIPTS) \
             $(MEMMAP_ALL) $(SYSCALL_ALL) $(LIBA_SRCS) $(BINSRC)/sh.s $(SH_PUT_MODS) \
             $(BINSRC)/testeval.s
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_e2efs_image.py

check-e2e-fs-host: $(E2E_SCRIPTS) $(E2EFS_SCRIPTS) $(SCRIPTS)/e2e_fs_selftest.py
	python3 $(SCRIPTS)/e2e_fs_selftest.py

check-e2e-fs: check-e2e-fs-host e2efs-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_e2e_fs.py $(E2EFSIMAGE)

$(BUILD)/expr.bin: $(BINSRC)/expr.eval.s $(BINSRC)/expr.ops.s $(BINSRC)/expr.match.s

# grepbody.s carries grep's whole implementation; grep.s is the
# manifest. Split 2026-09-21 for real Merlin's 41,215-byte source
# buffer -- the manifest plus its largest single put had reached
# 42,539 (check_dialect rule 3), and -F was what tipped it.
$(BUILD)/grep.bin: $(BINSRC)/grepbody.s

# trbody.s carries tr's implementation and tresc.s its input-set
# pre-pass (backslash escapes + [:class:]). Split 2026-09-21 for
# the vendored `as`'s 16,128-byte source window -- the ceiling that
# decides whether a unit can be rebuilt by maux itself, and a
# DIFFERENT number from real Merlin's 41,215-byte buffer.
$(BUILD)/tr.bin: $(BINSRC)/trbody.s $(BINSRC)/tresc.s

# timeoutsig.s is the signal-name half of timeoutparse.s, split
# 2026-09-21 for the same `as` source window: the manifest (9,268)
# plus its largest put (7,573) had reached 16,841 of 16,128.
$(BUILD)/timeout.bin: $(BINSRC)/timeoutsig.s

# xargsinv.s is INVOKE/TRACEPRINT, split out of xargsrun.s
# 2026-09-21 -- the FOURTH unit that day to cross `as`'s
# 16,128-byte source window when a flag was added to it.
$(BUILD)/xargs.bin: $(BINSRC)/xargsinv.s $(BINSRC)/xargssub.s

# chtypnum.s is chtyp's operand parsers, split 2026-09-21 for the
# `as` source window -- the FIFTH unit that day to cross it.
$(BUILD)/chtyp.bin: $(BINSRC)/chtypnum.s
# mntcom.s is mount's and umount's shared half (docs/VROOT.md).
$(BUILD)/mount.bin $(BUILD)/umount.bin: $(BINSRC)/mntcom.s
# mntdens.s is mount's densify half (docs/LOOP-S2.md S3).
$(BUILD)/mount.bin: $(BINSRC)/mntdens.s

# nulib2 is divided by CONCERN, not by byte budget: the archive
# structure (arc), what a listing prints (lst), turning a record into
# bytes (ext), ShrinkIt's chunked compressed stream and its RLE layer
# (lzw), the LZW algorithm itself (lzc), the read/seek/CRC primitives
# everything stands on (io), and the strings (msg).
#
# It was FOURTEEN files until 2026-09-21, every split forced by `as`'s
# 16,128-byte source window -- a ceiling that stopped binding when
# `nas` took over self-hosting, because nas streams. Those splits were
# real work spent on a stale constraint; see check_dialect.py hazard
# 3b for the ruling that retired it.
#
# EVERY piece must be listed here. nulib2ext.s was once left off, so
# `make` did not rebuild after it changed and a sabotage run measured
# the STALE binary -- the gate reported the old behaviour and passed,
# which is the one way a teeth proof lies.
$(BUILD)/nulib2.bin: $(BINSRC)/nulib2arc.s $(BINSRC)/nulib2lst.s \
                    $(BINSRC)/nulib2ext.s $(BINSRC)/nulib2add.s \
                    $(BINSRC)/nulib2af.s $(BINSRC)/nulib2rle.s \
                    $(BINSRC)/nulib2lze.s $(BINSRC)/nulib2lzw.s \
                    $(BINSRC)/nulib2lzc.s $(BINSRC)/nulib2io.s \
                    $(BINSRC)/nulib2msg.s

# ---------------------------------------------------------------------------
# interactive shell image (`make play-image`): src/test/playtest.s +
# scripts/build_play_image.py. Boots sh.bin with fd 0/1/2 attached to the
# kernel tty driver, then leaves the shell at an emulator keyboard prompt.
# `make check-play` smoke-tests that tty path through MCP keyboard/screen I/O.
# ---------------------------------------------------------------------------
PLAYTESTBLK      := $(BUILD)/MAUXPLAY.SYSTEM
PLAYIMAGE        := $(BUILD)/play.po
# the release disk (docs/FULLDISK.md): play.po's tree plus the native
# toolchain, headers, liba, maux's source and the examples, on a
# 65,535-block volume. NOT build/maux.po, which `make image` owns.
FULLIMAGE        := $(BUILD)/full.po
# EVERY module playtest.s PUTs must be listed, or editing it does not
# rebuild the image and the gate silently re-runs the old binary. tty.s,
# timer.s, procspawn.s, procfd.s and ultraterm.s were missing until
# 2026-08-17 -- which is exactly how a `check-play` teeth-check reported
# PASS twice against a tty.s change that had never been assembled.
PLAYTEST_DEPS    := $(SRC)/test/playtest.s $(SRC)/test/playtestb.s \
                     $(INC)/mm.lseg.equ \
                     $(SRC)/kernel/mouse.s $(SRC)/kernel/timer.s \
                     $(SRC)/kernel/byelaunch.s $(SRC)/kernel/kdevblk.s \
                     $(SRC)/kernel/kbye.s $(SRC)/kernel/loopseg.s \
                     $(KERNEL_PROC_MODS)

# ONE recipe produces all four files and it must run ONCE. GNU make 3.81
# reads `A B C D: deps` as four independent rules sharing a recipe, not as
# a grouped target (that is 4.3's `&:`): under -j the SYSTEM, KSEG and LSEG
# goals each started their own merlin32 + split_kseg.py on the same files
# and `[split-kseg] FAIL ... built file is 29902 B, expected flat +
# segment` aborted the build (KFIX8). KFIX8 cured the race with one real
# target and test-only followers, which made a hand-deleted KSEG or LSEG
# stop the build with "missing" where it used to rebuild (the followers
# cannot rebuild what the one recipe makes). What 3.81 DOES have is the
# pattern rule with several targets, documented to run its recipe once
# for all of them: stem PLAY here (build/MAUXPLAY.SYSTEM, ..._Output.txt,
# MAUXPLAY_KSEG, MAUXPLAY_LSEG), so any one missing rebuilds the set, and
# under -j that is still one merlin32 + split_kseg.py. (merlin32 writes
# _Output.txt BEFORE split_kseg.py rewrites SYSTEM, so the files are
# not "never older than SYSTEM"; the pattern rule does not need them to be.)
# The recipe keeps its own tests: a stem other than PLAY is refused.
# The explicit line names the image and its inputs for the scripts that
# read this Makefile (check-kernel-images, split_kseg.py); the recipe is
# the pattern rule's.
$(PLAYTESTBLK): $(PLAYTEST_DEPS) | $(BUILD)

$(BUILD)/MAUX%.SYSTEM $(BUILD)/MAUX%.SYSTEM_Output.txt $(BUILD)/MAUX%_KSEG $(BUILD)/MAUX%_LSEG: $(PLAYTEST_DEPS) | $(BUILD)
	@test "$*" = PLAY || { echo "no recipe for stem $* (only MAUXPLAY is built here)"; exit 1; }
	$(MERLIN32) -v1 $(SRC)/test/playtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(PLAYTESTBLK) || { echo "missing $(PLAYTESTBLK)"; exit 1; }
	@test -f $(PLAYTESTBLK)_Output.txt || { echo "missing $(PLAYTESTBLK)_Output.txt"; exit 1; }
	python3 $(SCRIPTS)/split_kseg.py MAUXPLAY
	@test -f $(BUILD)/MAUXPLAY_KSEG || { echo "missing $(BUILD)/MAUXPLAY_KSEG -- split_kseg.py found no segment"; exit 1; }
	@test -f $(BUILD)/MAUXPLAY_LSEG || { echo "missing $(BUILD)/MAUXPLAY_LSEG -- split_kseg.py found no low segment"; exit 1; }

# the by-products are named by scripts, not by a rule: keep make from
# treating them as deletable intermediates of the pattern rule.
# NOTE what makes rebuild-on-missing work: `play-image` is PHONY and
# lists SYSTEM, KSEG and LSEG as prerequisites, so a missing one is
# looked up as a target and found by the pattern rule. A future REAL
# FILE rule that consumes KSEG or LSEG (a stamp, an image of its own)
# does not get that for free: its dependency on a deleted file is
# only as good as the phony chain above, and .SECONDARY only stops
# deletion, it never rebuilds.
.SECONDARY: $(PLAYTESTBLK) $(PLAYTESTBLK)_Output.txt $(BUILD)/MAUXPLAY_KSEG $(BUILD)/MAUXPLAY_LSEG

# Manual pages: docs/man/*.1 (V7 man(1) nroff source, the artifact a
# period Unix ships) render to build/man/NAME.TXT -- 64 columns so a
# page reads on the 80-column glass without wrapping -- and the play
# image stages them at /usr/man/NAME for `more /usr/man/NAME`.
# The lock-selected mandoc renders deterministic ASCII with X\bX bold
# overstrikes, which build_play_image.py turns into SGR bold for the
# console. check-deps exercises a byte-level renderer probe; bootstrap-deps
# builds the locked source release into the provisioned dependency tree.
MAN_SRCS  := $(wildcard docs/man/*.1)
MAN_TXTS  := $(patsubst docs/man/%.1,$(BUILD)/man/%.TXT,$(MAN_SRCS))
man-pages: $(MAN_TXTS)
# A recipe that dies must not leave its target behind. build/man/admin.TXT
# was a ZERO-BYTE file dated to the run where mandoc was missing (exit
# 127): make then considered it built, and every later run reported
# "admin: empty, failed or stale render" without ever re-rendering it.
# Found 2026-09-20 on the first box sweep after mandoc was installed.
.DELETE_ON_ERROR:

.PHONY: public-tree check-all-host check-host-sweep check-lc check-altzp check-publish check-ascii check-doctruth check-prodos-version check-volname check-lsbig check-chtyp check-encoding check-nulib2
.PHONY: check-man check-man-image
check-man: man-pages
	python3 $(SCRIPTS)/check_man.py

check-man-image: play-image check-man
	python3 $(SCRIPTS)/check_man.py --image $(PLAYIMAGE)

$(BUILD)/man/%.TXT: docs/man/%.1 | $(BUILD)
	@mkdir -p $(BUILD)/man
	@"$(MANDOC)" -Tascii -O width=64 $< > $@
	@test -s $@ || { echo "man page $@ rendered empty"; exit 1; }

play-image: $(PLAYTESTBLK) $(BUILD)/MAUXPLAY_KSEG $(BUILD)/MAUXPLAY_LSEG $(UTIL_BINS) $(MAN_TXTS) \
                    $(BUILD)/byeres.bin $(BUILD)/byetenant.bin $(BUILD)/byetenantd.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_play_image.py

# `make play` -- the LIVE window a human uses, on the RELEASE disk
# (FULLDISK: the disk a developer plays with is the disk a person
# downloads; play.po stays the gates' base image). `--ut` puts the Videx
# UltraTerm in slot 3: fast_sdl installs the card ONLY with that flag
# (never by default), and for weeks the live launch line lacked it, so
# the play image booted 40-col and "80 columns" meant `vidmode 80` = the
# native-80 backend, the slowest scroller of the three (CONSOLE-OPT.md
# sec 6/7). `--green` because --crt mangles 80-column text. Override
# FAST_SDL if verilogapple lives elsewhere; PLAY_FLAGS adds to the line.
FAST_SDL  ?= $(VERILOGAPPLE)/sim/fast/fast_sdl
PLAY_FLAGS ?=
play: full-image
	@test "$(MAUX_TIER)" != build || { echo "this tree was bootstrapped with TIER=build, which has no verilogapple: the live window needs the test tier (docs/DEPENDENCIES.md)"; exit 2; }
	@test -x $(FAST_SDL) || { echo "missing $(FAST_SDL) -- build verilogapple's fast_sdl first"; exit 1; }
	cd $(dir $(FAST_SDL)) && ./fast_sdl --sdl --ut --green --caps-off $(PLAY_FLAGS) --disk $(abspath $(FULLIMAGE))

# Like `play`, but RECORD every keystroke (with its CPU cycle) to
# build/session.klog via VERILOGAPPLE_KEYLOG (docs/E2E-TERM.md). Do your
# repro, quit, then REPLAY it deterministically headless:
#   python3 scripts/e2e_vi_term.py replay build/session.klog [backend]
# -- turning a live session into a person-authored regression case.
play-rec: play-image
	@test "$(MAUX_TIER)" != build || { echo "this tree was bootstrapped with TIER=build, which has no verilogapple: the live window needs the test tier (docs/DEPENDENCIES.md)"; exit 2; }
	@test -x $(FAST_SDL) || { echo "missing $(FAST_SDL) -- build verilogapple's fast_sdl first"; exit 1; }
	cd $(dir $(FAST_SDL)) && VERILOGAPPLE_KEYLOG=$(abspath $(BUILD)/session.klog) \
	    ./fast_sdl --sdl --ut --green --caps-off $(PLAY_FLAGS) --disk $(abspath $(PLAYIMAGE))
	@echo "recorded keystrokes -> $(BUILD)/session.klog  (replay: python3 scripts/e2e_vi_term.py replay $(BUILD)/session.klog)"

check-play: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_play.py $(PLAYIMAGE)

# proshim (TASKS.md #19): the play image plus /mnt/MAUX/SHIM/TOY.SYSTEM, a
# hand-written ProDOS 8 system program run through `proshim`; the
# gate asserts its transcript and the file it leaves behind.
PROSHIMIMAGE := $(BUILD)/proshim.po


# check-mlival (TASKS.md #19): the DIFFERENTIAL. A portable MLI
# validator (src/test/mlival.s) runs under REAL ProDOS 8 (the oracle
# disk) and under proshim; the two transcripts must be byte-identical,
# which proves the shim reproduces ProDOS rather than agreeing with a
# fixture we also wrote.
MLIVALORACLE := $(BUILD)/mlival-oracle.po

# check-dd (file-level dd): boots the play image plus /mnt/MAUX/D's four
# raw fixtures and drives copy / skip+count / in-place seek+notrunc at
# the shell, each cmp'd against the fixture that says what dd should
# have produced. Byte-exactness is the fixture's job; the gate scrapes
# DDA=0/DDB=0/DDC=0. Teeth: break the skip multiply (DDA red) or the
# conv=notrunc in-place path (DDC red) -- each case cmps its OWN
# fixture, so neither can mask the other.
DDIMAGE := $(BUILD)/dd.po
dd-image: play-image $(BUILD)/dd.bin
	python3 $(SCRIPTS)/build_dd_image.py
check-dd: dd-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_dd.py $(DDIMAGE)

# check-partition (docs/PACE-1.md): the glass must not depend on how a
# byte stream is split into writes. A guest `dd bs=k` writes vim's own
# output (fixtures/partition/) and check-vt102's raw 131-byte fixture to
# the raw console for k in {1,2,3,7,64,whole}; the final glass and the
# raw text-page bytes must be identical for every k, on all three
# backends. No host timing enters, so it has teeth on the Mac.
PARTITIONIMAGE := $(BUILD)/partition.po

# check-devblk (docs/DEV-BLOCK.md): /dev/sNdM block devices. Boots
# the play image plus `dd` and /mnt/MAUX/DB's ground-truth fixtures
# (computed straight from the disk image's own bytes -- a .po file
# IS a raw ProDOS-ordered block image) beside a SECOND SmartPort unit
# (a copy of vendor/prodos-basic.po), and drives read (block-aligned
# and straddling), write+readback on the second unit, and the
# "no such device" refusal at the shell with dd/cmp/echo, check-dd's
# own idiom. Teeth: break PBLK_PREP's position decompose and STRAD
# goes red; drop the $F0 DEVLST mask and an open against a dirtied
# type-nibble byte misidentifies its unit (docs/DEV-BLOCK-NOTES.md
# has the manual transcript -- this emulator's own DEVLST entries
# carry a clean nibble, so the checked-in gate cannot show this red
# without also injecting a dirty byte, which it does not do yet).
DEVBLKIMAGE := $(BUILD)/devblk.po
DEVBLKIMAGE2 := $(BUILD)/devblk2.po

# check-floppy (docs/FLOPPY-E2E.md): the whole chain end to end -- a
# REAL 5.25" floppy (build/floppy.po, a 280-block/143,360-byte a2til
# volume, exactly verilogapple spec-12's slot-6 sector-image size)
# mounted on slot 6, `dd`'d through ProDOS's own Disk ][ driver via
# /dev/s6d1 (docs/DEV-BLOCK.md), archived with `nulib2 -a` into a
# .SDK (docs/NUFX.md slice 8), and proven byte-identical to the
# original three independent ways on the host: a2til's own
# disk_record.read(), real nulib2 -x, real nulib2 -i. build/
# floppyboot.po is the play image family plus `dd` staged (nulib2
# ships on play.po already, a UTILS member). Teeth (both CLI flags on
# check_floppy.py, not code sabotage): --teeth-order mounts the
# floppy with the wrong sector order and case (a) must go red, naming
# a sector; --teeth-badname archives to .SHK instead of .SDK and case
# (b) must go red with a2til's "not a single disk image".
FLOPPYIMAGE := $(BUILD)/floppy.po
FLOPPYBOOTIMAGE := $(BUILD)/floppyboot.po

# check-devfs (docs/DEVFS.md): the pseudo-root "/" and "/dev",
# listable. Boots the play image (unit 1, volume BASIC) plus a
# second, freshly created ProDOS volume SCRATCH (unit 2) and a DOS
# 3.3 floppy on slot 6 (fixtures/gem/XMASADV.SDK's own disk record,
# extracted via a2til's NuFX reader -- build_unpack_image.py's own
# load_sdk_oracle idiom -- and mounted with order "do"). Five cases
# driven at the shell: `ls /` (BASIC/dev/SCRATCH, no Disk ][ access
# -- disk2_state proven unmoved), `ls /dev` (the 7 fixed names then
# s6d1/s6d2/s7d1/s7d2, s3d2 absent), `cd /dev; ls s6d1` and `cd
# /mnt/MAUX; cd ..; pwd` -> "/" (docs/DEVFS-NOTES.md: the ".." fix
# actually lives in liba's MKP_POP, not the kernel's PRC_DOTDOT -- sh
# resolves ".." in MKPATH before SC_SETPFX ever sees one), a
# floppy-less reboot dropping s6d1/s6d2, and cat/ls failing on the
# synthetic paths exactly like a missing file. Teeth verified by hand
# this session (docs/DEVFS-NOTES.md has the transcripts), not wired
# as CLI flags: none of the three is a data-level corruption
# check_unpack.py's own --teeth-* flags could express.
DEVFSIMAGE := $(BUILD)/devfs.po
DEVFSIMAGE2 := $(BUILD)/devfs2.po
DEVFSFLOP := $(BUILD)/devfs_flop.do




# check-ps (docs/PS-ARGS.md): ps's COMMAND column -- argv joined and cut
# to the console, `(name)` when the program reused its argv block, `?`
# when the kernel knows nothing, `<defunct>` for a zombie -- and the
# kernel's SYS_PSTAT modes moving exactly the bytes they say. Fixtures
# are written by a2til; only the play image is a prerequisite.
check-ps: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ps.py


# check-shfd (docs/SH-FD.md): a subshell inherits the descriptors the
# user opened with `exec`, and `read` / `.` / the compound commands
# honour `<&N`. Typed rows against the host's dash (cross-checked
# against bash 5); fd 3 is always a file that is neither the script nor
# fd 0.
check-shfd: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shfd.py

# check-shprefix (docs/SH-PREFIX.md): `NAME=value cmd`, `sh -c STRING`, and
# a script whose own descriptor `exec N<F` cannot reach. Host oracle: dash
# and bash 5, as check-shfd.
check-shprefix: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shprefix.py

# check-shnlvar (docs/SH-NLVAR.md): a variable holding a newline survives
# `( )` and `$( )` byte for byte (the serialiser writes $8D as bit-7-clear
# $0D), and no line of a value runs as a command. Host oracle: dash and
# bash 5, as check-shfd. Teeth: scripts/teeth_shnlvar.py.
check-shnlvar: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shnlvar.py

# check-shforeign (docs/SH-FOREIGN.md): a script in ProDOS-standard text
# (low ASCII, $0D line ends) runs under sh (sh F, . F, sh < F); fixtures
# staged with a2til. Teeth: scripts/teeth_shforeign.py.
check-shforeign: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shforeign.py

# check-shmlquote (docs/SH-MLQUOTE.md): a quote left open, or a trailing
# backslash, continues the line (PS2 `> ` on the console, nothing from a
# script); an over-long line is refused whole; the seek mark, console-loop
# spooling, here-documents, history and the alias expander all see the
# LOGICAL line. Host oracle: dash and bash 5, as check-shfd. Part B drives
# the editor prompt. Teeth: scripts/teeth_shmlquote.py.
check-shmlquote: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shmlquote.py

# check-shexecloop (docs/SH-EXECLOOP.md): `for` takes `do CMD` (POSIX) in
# every layout -- `do CMD` on the do line, `for ..; do CMD` / done, the
# one-line loop in a file -- and replays right through backslash-newline
# continuations, quote-continued words and aliases before DO. Part A:
# script rows vs dash and bash 5, fresh scratch files, sentinel and
# `echo $?`, kernel buffer counters before/after; part B: the typed
# one-line loop and its recall from history. Teeth:
# scripts/teeth_shexecloop.py.
check-shexecloop: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shexecloop.py

# check-shseq (docs/SH-SEQ.md): warm `sh -c` loops (a reused bank must
# not keep the last script's seek mark), the one-line `case`, and the
# rest of the line after `.`. One console session; every row is typed,
# checked against dash and bash 5 (or a semantic WANT for diagnostics),
# per-row named failures. Teeth: scripts/teeth_shseq.py.
check-shseq: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shseq.py

# check-openrw (docs/OPEN-RW-1.md): sh's `>` and `>>` wait out a busy
# ($50) open -- under a real `tail -f`, over a phase sweep, with the
# guest's own retry counter as the proof a retry was TAKEN; bounded,
# ^C-interruptible, and no retry for any other error. Teeth:
# scripts/teeth_openrw.py.
check-openrw: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_openrw.py


# check-lseg (docs/LOOP-S1.md ruling): the play-only low segment's
# layout -- code/cells below the caches, the caches page-aligned and
# inside $1300-$1FFF, nothing of the harness below $1300 reaching up.
check-lseg: play-image
	python3 $(SCRIPTS)/check_lseg.py

# check-df (docs/DU-DF.md): `df` reports Used/Available from ONE
# GET_FILE_INFO on the volume directory (TRM: aux_type = total blocks,
# blocks_used = blocks for all files). The oracle is a2til opening the
# SAME image file and COUNTING THE BITMAP -- the road df no longer
# takes. Boots BASIC (unit 1) + SCRATCH (unit 2) + a DOS 3.3 floppy on
# slot 6 (disk2_state unchanged across `df`: never poll a Disk ][ to
# list), then a cp/rm on SCRATCH moves the numbers by the file's own
# blocks_used. Own image names (build_df_image.py), not devfs's: the
# sweep runs check-devfs in another lane.
df-image: play-image
	python3 $(SCRIPTS)/build_df_image.py
check-df: df-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_df.py $(BUILD)/df.po $(BUILD)/df2.po $(BUILD)/df_flop.do

# check-unpack (docs/UNPACK-E2E.md): the other direction from check-floppy
# and docs/NUFX.md's writer slices -- REAL .SHK/.SDK archives fetched from
# the wild (fixtures/PROVENANCE.md), unpacked onto a running maux. Three
# legs: A) `nulib2 -x` two real .SHK archives straight onto the hard drive
# (eight files total, byte- and type/aux-compared against host nulib2 -v/-x);
# B) a real ProDOS .SDK imaged onto a spare SmartPort unit (`dd ... of=
# /dev/s7d2 conv=notrunc`) and its files copied back with `cp`; C) a real
# DOS 3.3 .SDK imaged onto the unit and BOOTED from it standalone (slot 6,
# order "po"). build/unpack2.po is a fresh 280-block scratch volume, the
# "spare disk" for legs B/C. Teeth (CLI flags on check_unpack.py, each seen
# red then reverted): --teeth-corrupt flips a byte in XMASADV.SDK's LZW
# payload (CRC refusal); --teeth-order mounts leg C's exported image with
# the wrong sector order (no boot prompt); --teeth-type skips the leg A
# type-stamp comparison (proves it is load-bearing).
UNPACKIMAGE := $(BUILD)/unpack.po
UNPACK2IMAGE := $(BUILD)/unpack2.po
unpack-image: play-image $(BUILD)/dd.bin
	python3 $(SCRIPTS)/build_unpack_image.py
check-unpack: unpack-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_unpack.py $(UNPACKIMAGE) $(UNPACK2IMAGE)

# check-bpatch (spec-driven binary patcher): boots the play image plus
# /mnt/MAUX/B's synthetic fixtures and drives set/expect/flip-lc against a
# crafted target, cmp'd against the expected blob (BPA), plus the
# expect-guard refusal path (BPB=1) and proof a refused patch writes
# nothing (BPC=0). Teeth: drop flip-lc's $C0 guard (a control byte flips
# -> BPA red) or the expect check (BPB=0 and BPC red).
BPATCHIMAGE := $(BUILD)/bpatch.po
bpatch-image: play-image $(BUILD)/bpatch.bin
	python3 $(SCRIPTS)/build_bpatch_image.py
check-bpatch: bpatch-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_bpatch.py $(BPATCHIMAGE)

# check-plasma (docs/PLASMA-PORT.md): the native PLASMA runtime (M2).
# The PLASMA modules are compiled ON THE HOST by the sibling-repo
# toolchain -- xplasm (`make -C $(PLASMA)/src xplasm`, the C cross-
# compiler) and acme (`brew install acme`); xplasm writes <input>.a
# beside its input (hence the cp into $(BUILD)). rt is FLAT (-AOW
# --setpc 8192, JMP _INIT at $2000, self-linked); hello2 is a normal
# relocatable module (-AMOW, $6502) that `import cmdsys`. The seed
# flat-loads rt; rt.loadmod relocates hello2 and binds its PUTS import.
PLASMA         ?= $(HOME)/src/PLASMA
export PLASMA
XPLASM         := $(PLASMA)/src/xplasm
PLASMAIMAGE    := $(BUILD)/plasma.po
# M2: the runtime (src/plasma/rt.pla -- cmd.pla minus the shell, a
# cmdsys implementation over maux syscalls) and a second fixture that
# `import cmdsys` + puts() -- dependency resolution, ESD symbol binding,
# relocation onto the heap and the fd console proven in one line. Built
# by the same host toolchain; the fixture's include is copied beside it
# (xplasm resolves `include` relative to cwd). rt is staged only on the
# gate image -- promoting it into play.po would make every play-image
# gate need xplasm + acme.
#
# PLASMART/PLASMAHELLO2 are defined HERE, BEFORE plasma-image's own
# prerequisite list below, on purpose: an ordinary rule's prerequisites
# are expanded when make READS that rule, not deferred to build time,
# so a `$(VAR)` reference to a variable defined LATER in the file
# expands to empty right there -- plasma-image silently dropped both
# prerequisites (found 2026-09-08 chasing a stale-hello2.mod failure
# in the M3 work; check-plasma still passed because build artifacts
# from an earlier, differently-ordered build were already sitting in
# build/, masking the gap until a truly clean build hit it).
PLASMART       := $(BUILD)/rt.mod
PLASMAHELLO2   := $(BUILD)/hello2.mod
plasma-image: play-image $(BUILD)/plasma.bin \
               $(PLASMART) $(PLASMAHELLO2)
	python3 $(SCRIPTS)/build_plasma_image.py
$(PLASMART): $(SRC)/plasma/rt.pla | $(BUILD)
	cp $< $(BUILD)/rt.pla
	cd $(BUILD) && $(XPLASM) -AOW rt.pla
	acme --setpc 8192 -o $@ $(BUILD)/rt.a
$(PLASMAHELLO2): $(SRC)/test/plasma/hello2.pla \
                 $(SRC)/test/plasma/inc/cmdsys.plh | $(BUILD)
	mkdir -p $(BUILD)/inc
	cp $(SRC)/test/plasma/inc/cmdsys.plh $(BUILD)/inc/
	cp $< $(BUILD)/hello2.pla
	cd $(BUILD) && $(XPLASM) -AMOW hello2.pla
	acme --setpc 8190 -o $@ $(BUILD)/hello2.a
check-plasma: plasma-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_plasma.py $(PLASMAIMAGE)

# check-plasm (docs/PLASMA-PORT.md M3): plasm ITSELF runs on maux.
# plasm.mod's own dependency list (its .a's DCI STRINGs) is CMDSYS
# (= rt, already resident), ARGS, FILEIO, LONGJMP -- so those three
# are built the same way as hello2 (-AMOW, --setpc 8190, NOT -AOW;
# only rt is flat) and staged where rt's loadmod finds them: ARGS and
# LONGJMP straight from the sibling-repo sources (portable as-is --
# no ProDOS/MLI/console calls); FILEIO from src/plasma/fileio.pla,
# maux's retarget of libsrc/apple/fileio.pla (kernel-owned io_buffers,
# no MLI NEWLINE -- emulated in the read path instead, no language-
# card pokes to remove). PLASM's own build needs `inc/` and `toolsrc/`
# as siblings of its input (its `include`s are cwd-relative) plus
# `vmsrc/plvmzp.inc` for one inline-asm block (scanid) -- all already
# true from $(PLASMA)/src, so PLASM (and ARGS/LONGJMP, which also
# has a `vmsrc/plvmzp.inc` asm block) are built running xplasm/acme
# FROM that tree rather than copying it apart.
PLASMARGS_MOD    := $(BUILD)/args.mod
PLASMLONGJMP_MOD := $(BUILD)/longjmp.mod
PLASMFILEIO_MOD  := $(BUILD)/fileio.mod
PLASMPLASM_MOD   := $(BUILD)/plasm.mod
PLASMLIBINC      := $(SRC)/plasma/inc
PLASMIMAGE2      := $(BUILD)/plasm.po

$(PLASMARGS_MOD): $(PLASMA)/src/libsrc/args.pla | $(BUILD)
	cd $(PLASMA)/src && $(XPLASM) -AMOW libsrc/args.pla
	acme --setpc 8190 -o $@ $(PLASMA)/src/libsrc/args.a

$(PLASMLONGJMP_MOD): $(PLASMA)/src/libsrc/longjmp.pla \
                     $(PLASMA)/src/vmsrc/apple/plvmzp.inc | $(BUILD)
	mkdir -p $(BUILD)/libsrc $(BUILD)/vmsrc
	cp $(PLASMA)/src/libsrc/longjmp.pla $(BUILD)/libsrc/
	cp $(PLASMA)/src/vmsrc/apple/plvmzp.inc $(BUILD)/vmsrc/plvmzp.inc
	cd $(BUILD) && $(XPLASM) -AMOW libsrc/longjmp.pla
	cd $(BUILD) && acme --setpc 8190 -o $(abspath $@) libsrc/longjmp.a

$(PLASMFILEIO_MOD): $(SRC)/plasma/fileio.pla $(PLASMLIBINC)/cmdsys.plh \
                     $(PLASMLIBINC)/fileio.plh | $(BUILD)
	mkdir -p $(BUILD)/inc
	cp $(PLASMLIBINC)/cmdsys.plh $(PLASMLIBINC)/fileio.plh $(BUILD)/inc/
	cp $< $(BUILD)/fileio.pla
	cd $(BUILD) && $(XPLASM) -AMOW fileio.pla
	acme --setpc 8190 -o $@ $(BUILD)/fileio.a

# PLASM needs ONE patch, applied to a scratch copy of the sibling repo
# (never the checkout itself): toolsrc/plasm.pla hardcodes
# `const RELADDR = $1000` (upstream's own default -- real ProDOS PLVM's
# module load address), but maux's convention is RELADDR = $2000 (every
# ACME-built module here, and rt.pla's own loadmod, assume it). Left
# at $1000, plasm.pla still compiles and writes a well-FORMED .mod --
# magic, defcnt, RLD/ESD all present and byte-plausible -- but every
# header field it derives from RELADDR (defofst AND init, both
# `header_value + modofst` where modofst is computed from the ACTUAL
# $2000-based load address) comes out exactly $1000 low. loadmod()
# then computes the module's init/bytecode-def thunk address $1000
# short of where the module really landed, jumps into the MIDDLE OF
# RT'S OWN DATA (its `exports` table, observed at PC $2124-2125, a
# byte pattern that happens to decode as a self-referential `JMP` and
# spin forever -- no crash, no error, just silence and a hung shell).
# CONFIRMED by instrumented byte-level tracing (until_pc/break_set on
# the maux port's own opcode-handler addresses, cross-checked against
# a hand-verified module layout): the RLD fixup for T.MOD's external
# PUTS call IS applied correctly ($32F6, matched byte-for-byte against
# rt.pla's compiled `prstr`), and PUTS is NEVER REACHED -- confirming
# the divergence is in the init-thunk address, not the general loader
# or the VM's CALL/ICAL opcodes. Fix verified: with RELADDR patched to
# $2000, `plasma PLASM PLASM t.pla t.mod` compiles and
# `plasma t.mod` prints PLASM RAN and exits 0.
PLASMSRC_COPY    := $(BUILD)/plasmasrc
$(PLASMSRC_COPY)/.stamp: $(PLASMA)/src/toolsrc/plasm.pla \
                         $(PLASMA)/src/vmsrc/apple/plvmzp.inc
	mkdir -p $(PLASMSRC_COPY)
	rm -rf $(PLASMSRC_COPY)/toolsrc $(PLASMSRC_COPY)/inc $(PLASMSRC_COPY)/vmsrc
	cp -R $(PLASMA)/src/toolsrc $(PLASMSRC_COPY)/toolsrc
	cp -R $(PLASMA)/src/inc $(PLASMSRC_COPY)/inc
	cp -R $(PLASMA)/src/vmsrc $(PLASMSRC_COPY)/vmsrc
	cp $(PLASMA)/src/vmsrc/apple/plvmzp.inc \
		$(PLASMSRC_COPY)/vmsrc/plvmzp.inc
	sed 's/RELADDR           = $$1000/RELADDR           = $$2000/' \
		$(PLASMSRC_COPY)/toolsrc/plasm.pla > $(PLASMSRC_COPY)/plasm.tmp \
		&& mv $(PLASMSRC_COPY)/plasm.tmp $(PLASMSRC_COPY)/toolsrc/plasm.pla
	grep -q 'RELADDR           = $$2000' $(PLASMSRC_COPY)/toolsrc/plasm.pla
	touch $@

$(PLASMPLASM_MOD): $(PLASMA)/src/toolsrc/plasm.pla $(PLASMSRC_COPY)/.stamp
	cd $(PLASMSRC_COPY) && $(XPLASM) -AMOW toolsrc/plasm.pla
	cd $(PLASMSRC_COPY) && acme --setpc 8190 -o $(abspath $@) toolsrc/plasm.a

plasm-image: play-image $(BUILD)/plasma.bin $(PLASMART) \
             $(PLASMARGS_MOD) $(PLASMLONGJMP_MOD) $(PLASMFILEIO_MOD) \
             $(PLASMPLASM_MOD)
	python3 $(SCRIPTS)/build_plasm_image.py
check-plasm: plasm-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_plasm.py $(PLASMIMAGE2)

# check-nas (docs/AS-PLASMA.md L0): nas, a native maux assembler
# written in PLASMA, assembles a fixture module inside maux and its
# flat output is byte-identical to merlin32's. Same pattern as
# check-plasm: nas.mod is an ordinary relocatable module (-AMOW,
# --setpc 8190, RELADDR $2000 -- NOT plasm's flat/-AOW shape), its
# deps are CMDSYS (rt, already resident), ARGS, and FILEIO (maux's
# retarget) -- reused straight from the check-plasm build, no new
# host-toolchain step needed for them.
#
# NASARGS_MOD/NASFILEIO_MOD alias the already-defined plasm targets
# (built once, staged into both images) -- PLASMARGS_MOD/
# PLASMFILEIO_MOD are defined ABOVE this point in the file, so the
# alias is safe (the "define the var before the rule that expands
# it" trap from the plasm-image comment above).
NAS_MOD      := $(BUILD)/nas.mod
NASIMAGE     := $(BUILD)/nas.po
NASFIXTURE   := $(SRC)/test/asm/fixture.s
NASREF_BIN   := $(BUILD)/fixture.bin
NASSTRESS       := $(SRC)/test/asm/stress.s
NASSTRESSREF_BIN := $(BUILD)/stress.bin
NASLOCAL        := $(SRC)/test/asm/local.s
NASLOCALREF_BIN := $(BUILD)/local.bin
NASL2B          := $(SRC)/test/asm/l2b.s
NASL2BREF_BIN   := $(BUILD)/l2b.bin

# docs/AS-PROFILE.md's per-def-call-tax inlining experiment: a host
# `sed` macro pass over a SCRATCH copy of nas.pla (never the checkout
# itself), mirroring the PLASMSRC_COPY RELADDR-sed pattern above --
# copy to build/nasmac/, sed the copy, compile the copy. src/asm/
# nas.pla stays valid PLASMA with native ASM blocks (helper defs intact);
# scripts/nas_inline.sed documents exactly which calls it inlines and
# why (bare-variable-arg-only call sites, block- or ternary-shaped).
# $(NAS_MOD) below builds from this scratch copy, so check-nas/
# check-nas-rel/check-modules/profile-nas all exercise the inlined
# build -- a wrong expansion shows up as a byte mismatch, the
# correctness bar the task set.
NASMAC_DIR   := $(BUILD)/nasmac
$(NASMAC_DIR)/nas.pla: $(SRC)/asm/nas.pla scripts/nas_inline.sed | $(BUILD)
	mkdir -p $(NASMAC_DIR)
	sed -E -f scripts/nas_inline.sed $(SRC)/asm/nas.pla \
		> $(NASMAC_DIR)/nas.pla

$(NAS_MOD): $(NASMAC_DIR)/nas.pla $(PLASMLIBINC)/cmdsys.plh \
            $(PLASMLIBINC)/fileio.plh $(PLASMLIBINC)/args.plh | $(BUILD)
	mkdir -p $(BUILD)/inc
	cp $(PLASMLIBINC)/cmdsys.plh $(PLASMLIBINC)/fileio.plh \
		$(PLASMLIBINC)/args.plh $(BUILD)/inc/
	cp $< $(BUILD)/nas.pla
	cd $(BUILD) && $(XPLASM) -AMOW nas.pla
	acme --setpc 8190 -o $@ $(BUILD)/nas.a

# The oracle: merlin32 assembling the SAME fixture nas assembles
# inside the emulator. Built on the host from the generic %.bin
# pattern would fight the dsk-directive-less fixture (docs/AS-
# PLASMA.md's "oracle" section) -- simplest is to invoke merlin32
# directly and rename its (dsk-less, base-name) output.
$(NASREF_BIN): $(NASFIXTURE) | $(BUILD)
	rm -f $(SRC)/test/asm/fixture $(SRC)/test/asm/fixture_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt
	cd $(SRC)/test/asm && $(MERLIN32) fixture.s
	mv $(SRC)/test/asm/fixture $@
	rm -f $(SRC)/test/asm/fixture_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt

# L1a stress fixture (docs/AS-PLASMA.md milestone L1a): same pattern,
# a LARGER (>128 line, >32 symbol) self-contained source exercising
# the full 6502+65C02 opcode/addressing-mode set, every L1a data
# directive, the expression evaluator, and a forward-EQU chain.
$(NASSTRESSREF_BIN): $(NASSTRESS) | $(BUILD)
	rm -f $(SRC)/test/asm/stress $(SRC)/test/asm/stress_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt
	cd $(SRC)/test/asm && $(MERLIN32) stress.s
	mv $(SRC)/test/asm/stress $@
	rm -f $(SRC)/test/asm/stress_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt

# :local fixture (task #21, docs/AS-PLASMA.md): same pattern -- a
# self-contained source that ISOLATES :local zone resolution (within-
# zone fwd/back, the same name reused in a different zone, a cross-
# zone reference to a file-unique name) from every other directive.
$(NASLOCALREF_BIN): $(NASLOCAL) | $(BUILD)
	rm -f $(SRC)/test/asm/local $(SRC)/test/asm/local_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt
	cd $(SRC)/test/asm && $(MERLIN32) local.s
	mv $(SRC)/test/asm/local $@
	rm -f $(SRC)/test/asm/local_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt

# L2 fixture (task #21 gap-closure batch, docs/AS-PLASMA.md sec 6):
# DUM/DEND, ERR (satisfied), the `.`/`!`/`&` OR/EOR/AND operators, and
# a DSK line. l2b.s itself carries `dsk l2b.bin`, so merlin32 names
# its OWN output "l2b.bin" directly (measured -- DSK sets merlin32's
# default output name, task report) -- no rename needed, unlike the
# other fixtures above which have no DSK line and fall back to the
# source basename.
$(NASL2BREF_BIN): $(NASL2B) | $(BUILD)
	rm -f $(SRC)/test/asm/l2b.bin $(SRC)/test/asm/l2b.bin_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt
	cd $(SRC)/test/asm && $(MERLIN32) l2b.s
	mv $(SRC)/test/asm/l2b.bin $@
	rm -f $(SRC)/test/asm/l2b.bin_Output.txt \
		$(SRC)/test/asm/_FileInformation.txt

nas-image: play-image $(BUILD)/plasma.bin $(PLASMART) \
           $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(NAS_MOD) $(BUILD)/nas.cut \
           $(NASREF_BIN) $(NASSTRESSREF_BIN) $(NASLOCALREF_BIN) \
           $(NASL2BREF_BIN)
	python3 $(SCRIPTS)/build_nas_image.py
check-nas: nas-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_nas.py $(NASIMAGE)
	python3 $(SCRIPTS)/check_nas_locals.py --image $(NASIMAGE)
	python3 $(SCRIPTS)/check_nas_boundary.py $(NASIMAGE)
	python3 $(SCRIPTS)/check_nas_text.py $(NASIMAGE)

# check-nas-rel (docs/AS-PLASMA.md L1b): nas's PUT/USE splicing and
# REL object emission, proven end to end -- nas assembles two REL
# modules (one PUTs a third file, one EXTs a symbol the other ENTs),
# maux's OWN native linker (`ld`, build/ld.bin, staged bare as `LD`
# alongside everything else in /mnt/MAUX/PLLIB so the shell's current-
# directory PATH fallback finds it -- src/bin/shblt2.s) links them,
# and the linked program is SPAWNED and its exit status read back.
# Same play-image + rt/ARGS/FILEIO/NAS staging as nas-image; adds the
# three REL fixtures (src/test/asm/{relmain,relsub,rellib}.s) and
# ld.bin.
NASRELIMAGE  := $(BUILD)/nas-rel.po
RELMAIN_S    := $(SRC)/test/asm/relmain.s
RELSUB_S     := $(SRC)/test/asm/relsub.s
RELLIB_S     := $(SRC)/test/asm/rellib.s

nas-rel-image: play-image $(BUILD)/plasma.bin $(PLASMART) \
               $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(NAS_MOD) \
               $(BUILD)/ld.bin $(RELMAIN_S) $(RELSUB_S) $(RELLIB_S)
	python3 $(SCRIPTS)/build_nas_rel_image.py
check-nas-rel: nas-rel-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_nas_rel.py $(NASRELIMAGE)

# check-nas-real (docs/AS-PLASMA.md, task #21's L2->L3 follow-on): the
# honest test that can't be gamed by a fixture -- nas assembling a REAL
# maux util (`pwd`, the smaller of the liba-using utils' PUT closures)
# plus its FULL recursive PUT closure (14 files, ~115 KB combined
# source), diffed byte-for-byte against merlin32's own reference build
# (build/pwd.bin, via the generic $(BUILD)/%.bin rule). A REPORT gate,
# deliberately NOT in CHECK_ALL_TARGETS yet: see
# scripts/build_nas_real_image.py's header for why the source's own
# relative `put ../liba/...` lines must be REWRITTEN to flat absolute
# /mnt/MAUX/PLLIB/ paths before nas can resolve them at all (maux's kernel
# does not resolve ".." for an ordinary open, only for `cd`), and
# scripts/check_nas_real.py's header for the diagnostic posture.
NASREALIMAGE := $(BUILD)/nas-real.po
PWD_S        := $(SRC)/bin/pwd.s
PWD_BIN      := $(BUILD)/pwd.bin

nas-real-image: play-image $(BUILD)/plasma.bin $(PLASMART) \
                $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(NAS_MOD) \
                $(PWD_BIN)
	python3 $(SCRIPTS)/build_nas_real_image.py
check-nas-real: nas-real-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_nas_real.py $(NASREALIMAGE)

# check-nas-librel (docs/AS-LINKER-SPIKE.md, task #21's linker path):
# the answer to check-nas-real's memory wall, and the successor of the
# Sweet16-`as` check-librelas sweep (retired 2026-10-18). Instead of nas swallowing
# a util's whole PUT closure (pwd's is 115 KB), the closure is split the
# way the S9 REL route splits it for real Merlin (gen_rel_module.py):
# every liba module becomes a REL form assembled ONCE, each util's main
# and extracted bss become REL forms, COOKED nas (build/nas.cut,
# docs/PLASCUT.md) assembles them all inside maux from one staged sh
# script, and `ld -z` links each util. Every linked util must be BYTE-
# IDENTICAL to merlin32's flat monolithic build/<util>.bin. Utils whose
# staged source is predicted over nas's ~15 KB heap are skipped at
# staging with the number (build/nas-librel-plan.json); the checker's
# NAS_TIER2 pins the rest of the non-converting set, which may only
# shrink. pwd converted first (2026-09-13) once nas checked its heap,
# expanded PUT in place, stopped charging comment lines a line-table
# slot, and learned SYM+n addends on relocatable/EXT terms. Runs on
# the box like every gate since 2026-09-14 (box_provision.sh steps 6-7
# put the PLASMA fork, xplasm and acme 0.97 there; box_gate.sh exports
# PLASMA); sharded, ~7 min there from a clean build/.
NASLIBRELIMAGE := $(BUILD)/nas-librel.po

# The 33 KERNEL_MAINS images (check_librel.KERNEL_MAINS, derived here
# so the two cannot drift): the kernel segment generator reads their
# `-v1` LISTINGS, which each image's own rule writes as a side effect
# without declaring -- so the images are the dependable targets. Not
# built by `make image play-image`, which is all a fresh box tree has
# run (2026-09-14: the first S5 box run died on the first missing one).
# From scripts/kernel_mains.py, which is pure data with no imports: this runs
# at PARSE time, and when it lived in check_librel.py (whose import chain
# reaches a2til) a host with no ~/src/a2til -- every build-tier host's first
# `make`, and GNU make 3.81 does not export A2TIL to $(shell) -- got an
# EMPTY list in silence, and full-image failed on a missing listing
# (docs/DEPS-TIER-NOTES.md P3). An empty list is now a parse error.
KERNEL_LISTINGS := $(shell python3 -c "import sys; sys.path.insert(0,'$(SCRIPTS)'); import kernel_mains as km; print(' '.join(km.KERNEL_MAINS[m]['ref'] for m in sorted(km.KERNEL_MAINS)))")
$(if $(strip $(KERNEL_LISTINGS)),,$(error KERNEL_LISTINGS is empty: scripts/kernel_mains.py could not be read))

nas-librel-image: play-image $(BUILD)/plasma.bin $(PLASMART) \
                  $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(NAS_MOD) \
                  $(BUILD)/ld.bin $(UTIL_BINS) \
                  $(BUILD)/plasma.bin_Output.txt \
                  $(BUILD)/proshim.bin_Output.txt \
                  $(BUILD)/proshimpg.bin_Output.txt \
                  $(KERNEL_LISTINGS)
	python3 $(SCRIPTS)/build_nas_librel_image.py
check-nas-librel: nas-librel-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_nas_librel.py $(NASLIBRELIMAGE)

# check-nas-selfmake (nas L3 S5, docs/AS-STREAM.md): the nas twin of
# check-selfmake (retired 2026-10-18) -- maux types `make` over a staged MAKEFILE whose
# recipes are nas assemblies and ld links, rebuilds every util and
# MAUXPLAY.SYSTEM byte-identical, and a `make -n` rerun has nothing
# to do. One boot, make-driven (not sharded).
NASSELFMAKEIMAGE := $(BUILD)/nas-selfmake.po
nas-selfmake-image: play-image $(BUILD)/plasma.bin $(PLASMART) \
                  $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(NAS_MOD) \
                  $(BUILD)/ld.bin $(BUILD)/make.bin $(UTIL_BINS) \
                  $(BUILD)/plasma.bin_Output.txt \
                  $(BUILD)/proshim.bin_Output.txt \
                  $(BUILD)/proshimpg.bin_Output.txt \
                  $(KERNEL_LISTINGS)
	NAS_SELFMAKE=1 python3 $(SCRIPTS)/build_nas_librel_image.py
check-nas-selfmake: nas-selfmake-image $(MCP_SUPERVISOR)
	NAS_SELFMAKE=1 python3 $(SCRIPTS)/check_nas_librel.py $(NASSELFMAKEIMAGE)
	python3 $(SCRIPTS)/check_nas_grow_guest.py --image $(NASSELFMAKEIMAGE)

# The cheap half of the native world rebuild. Constructing the image runs the
# composer and asserts every generated graph limit against make.s's live
# equates; check_nas_libpath.py resolves every `ld -l` in the staged MAKEFILE
# the way the guest's ld will (KFIX4 item 1: the kernel half was dead for 19
# days because `-l k` scanned a directory with no objects in it). Executing
# the MAKEFILE is check-nas-selfmake: 10.55 billion emulated cycles, 7 min 22 s
# wall on the Mac with the image build (KFIX4-NOTES sec 1.6) -- in the sweep
# since KFIX4, because a native rebuild nobody runs is a rebuild nobody has.
check-nas-selfmake-image: nas-selfmake-image
	python3 $(SCRIPTS)/check_nas_memory_model.py
	python3 $(SCRIPTS)/check_nas_libpath.py
	@echo "[check-nas-selfmake-image] PASS: native self-host image and graph fit"

# check-plascut (docs/PLASCUT.md): the plasma cutter. scripts/plascut.py
# does rt's loadmod on the HOST -- relocates + binds FILEIO/ARGS/NAS
# against rt's export table, builds the def thunks, appends the init
# list + a restore table with pristine copies of every writable data
# range -- and writes seed+rt+modules as ONE flat BIN (aux $0800) that
# the kernel spawns like `ls`, so lazy free's no-copy warm respawn
# covers the whole program, not just the 3 KB seed. `nas` is thereby a
# plain util (`nas -o X Y`, no `plasma NAS`) -- what `make` needs.
# cookt.cut is the restore-teeth fixture (src/test/plasma/cookt.pla).
PLASCUT       := $(SCRIPTS)/plascut.py
NAS_CUT       := $(BUILD)/nas.cut
COOKT_MOD     := $(BUILD)/cookt.mod
COOKT_CUT     := $(BUILD)/cookt.cut
PLASCUTIMAGE  := $(BUILD)/plascut.po
# Optional independent CPU oracle; requires ACME and py65 on the host.
# Not in check-all: production/builds acquire no new Python dependency.
.PHONY: check-nas-native
check-nas-native:
	python3 $(SCRIPTS)/check_nas_native.py
	python3 $(SCRIPTS)/check_nas_grow_native.py
	python3 $(SCRIPTS)/check_nas_line_native.py --require-native
	python3 $(SCRIPTS)/check_nas_note_native.py
	python3 $(SCRIPTS)/check_nas_commit_native.py

$(NAS_CUT): $(PLASCUT) $(BUILD)/plasma.bin $(PLASMART) $(PLASMARGS_MOD) \
            $(PLASMFILEIO_MOD) $(NAS_MOD)
	python3 $(PLASCUT) --const-prefix NAS --immutable-native NAS -o $@ NAS
$(COOKT_MOD): $(SRC)/test/plasma/cookt.pla $(PLASMLIBINC)/cmdsys.plh | $(BUILD)
	mkdir -p $(BUILD)/inc
	cp $(PLASMLIBINC)/cmdsys.plh $(BUILD)/inc/
	cp $< $(BUILD)/cookt.pla
	cd $(BUILD) && $(XPLASM) -AMOW cookt.pla
	acme --setpc 8190 -o $@ $(BUILD)/cookt.a
$(COOKT_CUT): $(PLASCUT) $(BUILD)/plasma.bin $(PLASMART) $(COOKT_MOD)
	python3 $(PLASCUT) --immutable-native COOKT -o $@ COOKT
# FULLDISK (docs/FULLDISK.md, SITE.md D2): the release disk with all the
# fruit -- play.po's tree on a 65,535-block volume, plus the native
# toolchain, /usr/inc, /usr/lib/LIBA, /usr/src/maux with its MAKEFILE,
# /usr/src/examples and the real NuFX archives. The file is full.po and
# NOT maux.po: build/maux.po is the 800-block kernel image `make image`
# builds, which check-boot, check-mame and mcp_drive.py boot.
# PHONY on purpose, like play-image: a gate boots a write-through copy,
# and the builder publishes by flock + atomic rename (imglock.py), so two
# sweep lanes that reach it queue instead of colliding. It needs the
# gates' emulator for exactly one step -- nas assembling liba -- and
# caches the result (build/full-liba/<hash>).
PLASM_CUT     := $(BUILD)/plasm.cut
# /bin/plasm links its OWN FILEIO: src/plasma/fileio.pla with the inc/ ->
# /usr/inc fallback ADDED (scripts/splice_fileio.py, from fileio.frag.pla),
# the read-only fallback only plasm wants (docs/PLASM-FIX-NOTES.md). plascut
# takes the first FILEIO.mod on its -L path, so nas and every other tool keep
# the base module, which carries no fallback code at all.
PLASMFIO_DIR := $(BUILD)/plasmfio
$(PLASMFIO_DIR)/fileio.mod: $(SRC)/plasma/fileio.pla $(SRC)/plasma/fileio.frag.pla \
                            $(SCRIPTS)/splice_fileio.py $(PLASMLIBINC)/cmdsys.plh \
                            $(PLASMLIBINC)/fileio.plh | $(BUILD)
	mkdir -p $(PLASMFIO_DIR)/inc
	cp $(PLASMLIBINC)/cmdsys.plh $(PLASMLIBINC)/fileio.plh $(PLASMFIO_DIR)/inc/
	python3 $(SCRIPTS)/splice_fileio.py $(SRC)/plasma/fileio.pla $(SRC)/plasma/fileio.frag.pla > $(PLASMFIO_DIR)/fileio.pla
	cd $(PLASMFIO_DIR) && $(XPLASM) -AMOW fileio.pla
	acme --setpc 8190 -o $@ $(PLASMFIO_DIR)/fileio.a
$(PLASM_CUT): $(PLASCUT) $(BUILD)/plasma.bin $(PLASMART) $(PLASMARGS_MOD) \
              $(PLASMFILEIO_MOD) $(PLASMLONGJMP_MOD) $(PLASMPLASM_MOD) \
              $(PLASMFIO_DIR)/fileio.mod
	python3 $(PLASCUT) -L $(PLASMFIO_DIR) -L $(BUILD) -o $@ PLASM
# DEMO-PLASMA (docs/SITE.md L6): Dave Schmenk's hello.pla, byte for byte,
# compiled on the HOST by xplasm (-AMW, no optimizer: the native plasm has
# none, so the module is the one the machine compiles, ESD numbering aside;
# the film checks that) and cooked by plascut into one spawnable
# BIN, staged as /usr/src/examples/HELLOPLA/HELLO. The cooking happens on the
# host; check-plasma-examples holds the cooked file to a fresh cook.
HELLOPLA_DIR := $(BUILD)/hellopla
HELLOPLA_CUT := $(BUILD)/hellopla.cut
# The module depends on the compiler flags too: HELLOPLA_FLAGS is written to
# a stamp file only when it differs from what is there, so a tree that built
# the old flags rebuilds (make re-reads the stamp's mtime after the recipe).
HELLOPLA_FLAGS := -AMW
.PHONY: hellopla-flags-force
hellopla-flags-force:
$(HELLOPLA_DIR)/flags: hellopla-flags-force | $(BUILD)
	mkdir -p $(HELLOPLA_DIR)
	echo '$(HELLOPLA_FLAGS)' > $@.new
	cmp -s $@.new $@ || mv $@.new $@
	rm -f $@.new
$(HELLOPLA_DIR)/hello.mod: examples/hellopla/hello.pla $(PLASMLIBINC)/cmdsys.plh $(HELLOPLA_DIR)/flags | $(BUILD)
	mkdir -p $(HELLOPLA_DIR)/inc
	cp $(PLASMLIBINC)/cmdsys.plh $(HELLOPLA_DIR)/inc/
	cp examples/hellopla/hello.pla $(HELLOPLA_DIR)/hello.pla
	cd $(HELLOPLA_DIR) && $(XPLASM) $(HELLOPLA_FLAGS) hello.pla
	acme --setpc 8190 -o $@ $(HELLOPLA_DIR)/hello.a
$(HELLOPLA_CUT): $(PLASCUT) $(BUILD)/plasma.bin $(PLASMART) $(HELLOPLA_DIR)/hello.mod
	python3 $(PLASCUT) -L $(HELLOPLA_DIR) -L $(BUILD) -o $@ HELLO
# nas runs in the emulator only in the test tier; the build tier takes the
# LIBA objects from pinned/liba (docs/DEPS-TIER.md).
FULL_IMAGE_EMU := $(if $(filter build,$(MAUX_TIER)),,$(MCP_SUPERVISOR))
full-image: play-image $(PLASM_CUT) $(NAS_CUT) $(HELLOPLA_CUT) $(BUILD)/plasma.bin $(PLASMART) \
            $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(PLASMLONGJMP_MOD) $(NAS_MOD) \
            $(BUILD)/ld.bin $(BUILD)/make.bin $(UTIL_BINS) \
            $(BUILD)/plasma.bin_Output.txt \
            $(BUILD)/proshim.bin_Output.txt \
            $(BUILD)/proshimpg.bin_Output.txt \
            $(KERNEL_LISTINGS) $(wildcard examples/*/*) \
            $(SRC)/plasma/inc/cmdsys.plh \
            $(wildcard fixtures/*.md fixtures/*/*) $(FULL_IMAGE_EMU)
	python3 $(SCRIPTS)/build_full_image.py
# play-image is named directly so sweep_par.sh puts this gate in the
# serial play.po lane: full.po is built FROM play.po, which a gate in
# that lane may be booting write-through at the same moment.
check-full: play-image full-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_full.py $(FULLIMAGE)

# The lesson ladder (docs/EXAMPLES.md, docs/SITE.md sec 5): every lesson of
# /learn/ typed on build/full.po, a key at a time, one fresh boot per
# lesson, and the settled session of each written to
# build/examples/<lesson>/session.txt, which site/build.py includes in the
# lesson page. play-image is named for the same reason as check-full:
# full.po is composed from play.po, so the gate belongs in the serial
# play.po lane.
#
# check-examples is the ONLY writer of the sessions. `make site` and
# `make check-site` read what is there and never run the emulator: a lesson
# page whose session is missing, or was written on another build/full.po
# (each session records the disk's sha256 in a header the page does not show),
# is an error that says "run make check-examples". SITE_FLAGS=--skip-lessons
# builds the site without lesson pages.
check-examples: play-image full-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_examples.py $(FULLIMAGE)

# check-plasm-full (docs/PLASM-FIX-NOTES.md): the cooked /bin/plasm on the
# release disk compiles Dave's own samplesrc/hello.pla, typed on the
# machine, and the result runs. play-image is named for the reason
# check-full's comment gives.
check-plasm-full: play-image full-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_plasm_full.py $(FULLIMAGE)

# The LIBA half of the pins (docs/DEPS-TIER.md): boots nas FRESH, bypassing
# build/full-liba, and requires every /usr/lib/LIBA object to equal
# pinned/liba. play-image is named for the same reason as check-full: it
# composes from play.po, so it belongs in the serial play.po lane.
check-liba-pins: play-image full-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/build_full_image.py --check-pins

# Re-pinning (docs/DEPS-TIER-NOTES.md P6): each target builds what it pins
# FIRST, so a hand re-pin on a stale build/ cannot pin objects from an old
# nas or an old patches.py. Test tier only (they need the emulator).
.PHONY: repin-liba repin-ascore
repin-liba: play-image full-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/build_full_image.py --repin-liba
repin-ascore: ascore-warm-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ascore.py --variant warm
	cp $(BUILD)/ascore-warm-as.obj $(BUILD)/ascore-warm-bank1.obj pinned/
	python3 $(SCRIPTS)/pinned.py repin

plascut-image: play-image $(NAS_CUT) $(COOKT_CUT) $(BUILD)/plasma.bin \
               $(PLASMART) $(PLASMARGS_MOD) $(PLASMFILEIO_MOD) $(NAS_MOD) \
               $(NASREF_BIN) $(NASSTRESSREF_BIN)
	python3 $(SCRIPTS)/build_plascut_image.py
.PHONY: check-plascut-host
check-plascut-host: $(NAS_CUT) $(COOKT_CUT)
	python3 $(SCRIPTS)/check_plascut_host.py
check-plascut: plascut-image check-plascut-host $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_plascut.py $(PLASCUTIMAGE)

# docs/AS-PROFILE.md: nas-vs-as per-line assembly THROUGHPUT
# measurement on verilogapple -- does a better-architected assembler in
# PLASMA bytecode beat the Sweet16 Merlin-8 core in cycles/line? A
# MEASUREMENT, not a gate: no pass/fail, deliberately NOT wired into
# CHECK_ALL_TARGETS. Same play-image + rt/ARGS/FILEIO/NAS staging as
# nas-image, plus `as.bin` (PLAY_EXCLUDEd, staged here the way
# build_play_image.py stages an ordinary util) and the two prof_*.s
# throughput fixtures.
PROFILEIMAGE := $(BUILD)/profile.po
PROFSMALL_S  := $(SRC)/test/asm/prof.small.s
PROFLARGE_S  := $(SRC)/test/asm/prof.large.s
# symbol-LIGHT companions (docs/AS-PROFILE.md): same shape, but the
# repeating block declares no label and references no symbol, so
# symbol-table work stays constant across N -- isolates the pure
# per-line language/VM cost from the symtab algorithm being measured
# above.
PROFLEANSM_S := $(SRC)/test/asm/profleansmall.s
PROFLEANLG_S := $(SRC)/test/asm/profleanlarge.s





# POSIX more (scripts/check_more.py): raw keys, backward motion on a
# file and on a spilled pipe, search, two operands, -n, the copy path.
check-more: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_more.py $(PLAYIMAGE)

# Every program that spawns must say WHY a spawn was refused, not only
# sh (scripts/check_spawnfail.py, docs/SPAWNFAIL-AUDIT.md): the process
# table is filled to ONE free bank and each of twelve spawners is run.
check-spawnfail: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_spawnfail.py $(PLAYIMAGE)


# vi total-coverage functional suite (scripts/check_vi.py): boots the
# play image and drives vi through every implemented command -- motions,
# paging, insert entry, operators, change/undo, ex bridge, search, and
# file round-trips -- one self-contained case each, so ONE run reports
# every broken feature instead of finding them piecemeal. The systematic
# replacement for hand-hunting vi bugs (found t/;/new-file naming this
# way, 2026-09-04).
check-vi: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_vi.py $(PLAYIMAGE)




# The shell's own line editor at the interactive console prompt
# (scripts/check_shedit.py; src/bin/shedit.s, docs/TAB-A2.md): raw only
# while sh reads the prompt, cooked for every child; ^C/^Z/^D, type-
# ahead, console switch, per-shell history, `trap ... INT`, the 127
# cap, and a key-script parity matrix against the kernel's editor
# (`sh -E`). Gate.
check-shedit: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_shedit.py all

# TAB completion in that editor (scripts/check_tabcomp.py; src/bin/
# shtabc.s, shtabc2.s, docs/TAB-A3.md): TAB completes, TAB TAB lists;
# commands from the resolver's own sources, pathnames through the
# glob walker (/, /dev, /mnt included); every refusal; the cursor
# rules; the 31-stored/all-counted scan; type-ahead; the readers that
# must NOT complete; and the LC bytes the placement leans on, poisoned
# and re-read. Teeth: scripts/teeth_tabcomp.py (19 sabotages).
check-tabcomp: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_tabcomp.py all







# POSIX vi (XCU `vi`) conformance suite (scripts/check_posixvi.py):
# recreates the POSIX spec's command semantics as concrete cases,
# checked BYTE-EXACT against a real host vim oracle (not the screen
# glass) via a2til reads of the written files, and reports PASS/FAIL
# per case -- a conformance REPORT, not a gate. Deliberately NOT in
# CHECK_ALL_TARGETS: it is slow (one emulator boot per <=3 cases, the
# play image's /mnt/MAUX directory only has 4 free entries). A case in the
# 'gap' category is EXPECTED to fail on a documented maux gap (none today:
# 66 of 66 pass); failure here is informational, not a build-breaking
# regression.
check-posixvi: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_posixvi.py $(PLAYIMAGE)

# POSIX ex (XCU `ex`) conformance suite (scripts/check_posixex.py): the
# ex analogue of check-posixvi above -- same posture (a conformance
# REPORT, not a gate; deliberately NOT in CHECK_ALL_TARGETS) and the
# same byte-exact-vs-host-oracle method, but driven through maux's own
# shell (`EX file < script > out`, staged with a2til into a subdirectory
# that grows on demand) rather than emulator keystrokes, since ex is a
# script-fed line editor rather than a full-screen one. Several cases
# are EXPECTED to fail on documented gaps/divergences (no standalone
# `&`, no `l`/`z`, no `+N`/`-N` relative addressing, bare `,`/`;` do not
# match POSIX, and maux echoes `?` for refusals real ex's batch mode
# stays silent about) -- see that script's own module docstring.
check-posixex: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_posixex.py $(PLAYIMAGE)


# glob matcher (src/liba/glob.s), exercised on the real 6502 by a case
# table -- see scripts/check_glob.py for why it earns a gate of its own.
GLOBTESTBLK := $(BUILD)/MAUXGLOB.SYSTEM
GLOBIMAGE   := $(BUILD)/glob.po

$(GLOBTESTBLK): $(SRC)/test/globtest.s $(SRC)/liba/glob.s $(LIBA_SRCS) | $(BUILD)
	$(MERLIN32) $(SRC)/test/globtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(GLOBTESTBLK) || { echo "missing $(GLOBTESTBLK)"; exit 1; }

glob-image: $(GLOBTESTBLK)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_glob_image.py

check-glob: glob-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_glob.py $(GLOBIMAGE)

# liba's string walk (src/liba/string.s), exercised on the real 6502 by a
# case table -- same shape as check-glob above, and it earns a gate of its
# own for a reason check-fleet cannot cover: the compare bug is reachable
# through `sort -u` (check-fleet's TWININ), but NO program in the tree can
# hand STRCPY a 256-byte source or STRCMPI a long name, so those two are
# testable only directly. See scripts/check_string.py's header.
STRTESTBLK  := $(BUILD)/MAUXSTR.SYSTEM
STRIMAGE    := $(BUILD)/str.po

$(STRTESTBLK): $(SRC)/test/strtest.s $(SRC)/liba/string.s $(LIBA_SRCS) | $(BUILD)
	$(MERLIN32) $(SRC)/test/strtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(STRTESTBLK) || { echo "missing $(STRTESTBLK)"; exit 1; }

str-image: $(STRTESTBLK)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_str_image.py

check-string: str-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_string.py $(STRIMAGE)

# ---------------------------------------------------------------------------
# UltraTerm 80-column backend (`make check-ultraterm`): src/test/uttest.s
# drives src/kernel/ultraterm.s on a machine with a Videx UltraTerm in slot 3.
#
# The verdict comes from verilogapple's `ultraterm_state`, NOT screen_text:
# the card has its own VRAM and its own video output, and it is write-only
# over the bus, so nothing else can see what the driver drew. See
# docs/CONSOLE.md section 10a.
#
# A ProDOS SYSTEM image rather than a boot block -- the module's row tables
# and 80-byte row-0 buffer put it past build_image.py's 512-byte block-0
# ceiling.
# ---------------------------------------------------------------------------
UTTESTBLK       := $(BUILD)/MAUXUT.SYSTEM
UTIMAGE         := $(BUILD)/ut.po
UTTEST_DEPS     := $(SRC)/test/uttest.s $(SRC)/kernel/ultraterm.s $(SRC)/kernel/ultraterm2.s \
                    $(MEMMAP_ALL) $(EQU_KERNEL)

$(UTTESTBLK) $(UTTESTBLK)_Output.txt: $(UTTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/uttest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(UTTESTBLK) || { echo "missing $(UTTESTBLK)"; exit 1; }
	@test -f $(UTTESTBLK)_Output.txt || { echo "missing $(UTTESTBLK)_Output.txt"; exit 1; }



# ---------------------------------------------------------------------------
# v1 basic-system suite (`make check-v1-system`): reuses the sh launcher
# above, but stages a broader script that drives sh + ls/cat/echo/cp/rm/ed as
# a small working system. Host-side verification mounts the mutated ProDOS
# image and asserts final file bytes plus directory membership.
# ---------------------------------------------------------------------------
V1SYSTEMIMAGE   := $(BUILD)/v1_system.po

# Shared utility volume (build/bin.po, volume UTILS): the userland binaries
# live here ONCE and gate images mount it as a second unit instead of each
# restaging ~78 blocks of them. See scripts/build_bin_image.py.
BINIMAGE        := $(BUILD)/bin.po

bin-image: $(UTIL_BINS)
	python3 $(SCRIPTS)/build_bin_image.py

v1-system-image: $(SHTESTBLK) $(UTIL_BINS)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_v1_system_image.py

check-v1-system: v1-system-image bin-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_v1_system.py $(V1SYSTEMIMAGE) $(BINIMAGE)

# ---------------------------------------------------------------------------
# ed (regex + line editor, src/liba/regex.s + src/bin/ed.s): the `make
# check-ed` ProDOS-booted acceptance gate, fileprocess harness pattern
# (src/test/edtest.s installs the real build/ed.bin as /bin/ED, drives
# it through two full sessions via real fd 0/1 redirection -- no tty).
# EDBIN is already built as part of $(UTIL_BINS) (UTILS above includes
# `ed`) -- named here only so this section's own targets can depend on it
# by its real path without re-deriving $(BUILD)/ed.bin inline.
# ---------------------------------------------------------------------------
EDBIN          := $(BUILD)/ed.bin
EDTESTBLK      := $(BUILD)/MAUXEDTEST.SYSTEM
EDTESTIMAGE    := $(BUILD)/ed.po
EDTEST_DEPS    := $(SRC)/test/edtest.s $(SRC)/test/edtestb.s \
                   $(SRC)/test/edtestb2.s $(KERNEL_PROC_MODS)

$(EDTESTBLK) $(EDTESTBLK)_Output.txt: $(EDTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/edtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(EDTESTBLK) || { echo "missing $(EDTESTBLK)"; exit 1; }
	@test -f $(EDTESTBLK)_Output.txt || { echo "missing $(EDTESTBLK)_Output.txt"; exit 1; }

# Rebuilt every time (PHONY), not just when the .SYSTEM/ed.bin change --
# same reasoning as mli-image: a prior successful run leaves EDSCR1/
# EDFILE/etc ON the image (verilogapple's smartport model writes through
# to the host .po file), and a second run against the SAME image fails
# CREATE with "duplicate filename" -- always start from a fresh copy of
# the carrier volume.
ed-image: $(EDTESTBLK) $(EDBIN)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_ed_image.py

# FAST BACKEND, same posture as check-fileprocess/check-mli (behavior,
# not hardware fidelity -- HACKING.md's fast/rtl split; nothing here
# exercises timing- or softswitch-fidelity-sensitive behavior).
check-ed: ed-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ed.py $(EDTESTIMAGE)

# ---------------------------------------------------------------------------
# ex (swap-file-backed line editor, M1 -- docs/EX-DESIGN.md sec 5): the
# `make check-ex` ProDOS-booted acceptance gate, same fileprocess/ed
# harness pattern (src/test/extest.s installs the real build/ex.bin as
# /bin/EX, drives one session through real fd 0/1 redirection -- no
# tty). EXBIN is already built as part of $(UTIL_BINS) -- named here only
# so this section's own targets can depend on it by its real path.
# ---------------------------------------------------------------------------
EXBIN          := $(BUILD)/ex.bin
EXTESTBLK      := $(BUILD)/MAUXEXTEST.SYSTEM
EXTESTIMAGE    := $(BUILD)/ex.po
EXTEST_DEPS    := $(SRC)/test/extest.s $(SRC)/test/extestb.s \
                   $(SRC)/test/extestb2.s $(SRC)/test/extestb3.s \
                   $(SRC)/test/extestb4.s $(SRC)/test/extestb5.s \
                   $(SRC)/test/extestb6.s $(SRC)/test/extestb7.s \
                   $(SRC)/test/extestb8.s $(SRC)/test/extestb9.s \
                   $(KERNEL_PROC_MODS)

$(EXTESTBLK) $(EXTESTBLK)_Output.txt: $(EXTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/extest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(EXTESTBLK) || { echo "missing $(EXTESTBLK)"; exit 1; }
	@test -f $(EXTESTBLK)_Output.txt || { echo "missing $(EXTESTBLK)_Output.txt"; exit 1; }

# Rebuilt every time (PHONY), same reason as ed-image: a prior successful
# run leaves EXCAP1/EXOUT1/etc ON the image (and `w!`s back into staged
# fixtures like EXSRC6), so a second run against the SAME image fails
# CREATE with "duplicate filename" or reads a mutated fixture. The
# fixtures/scripts themselves are staged by build_ex_image.py (FIXTURES,
# 2026-09-08 -- they used to be embedded in MAUXEXTEST.SYSTEM). sh.bin/
# sort.bin/cat.bin are also staged (as /bin/sh,SORT,CAT) -- the 2026-09-06 `!`
# family's own session 9 spawns `sh` for real, which spawns `sort`/`cat`
# in turn (PATHRSLV resolves both against PATHTAB's "/mnt/MAUX/" entry).
ex-image: $(EXTESTBLK) $(EXBIN) $(BUILD)/sh.bin $(BUILD)/sort.bin \
                $(BUILD)/cat.bin
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_ex_image.py

check-ex: ex-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ex.py $(EXTESTIMAGE)

# io_buffer LENDING regressions (docs/IOBUF-LENDING.md sec 5; the
# 2026-09-07 review's IB1-IB5). Runs a generated probe process
# against the shipping play image (a COPY -- build/iobuf/<mode>.po),
# one boot per mode; the fault modes patch one kernel helper in
# emulator RAM by symbol and restore it.
check-iobuf: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_iobuf.py


# OPEN-RO-2 (docs/OPEN-RO-2-NOTES.md): the read-intent open ($83 in
# SYS_OPEN's param_count) -- `exec 3<F 4<F`, cmp/diff/comm/join/
# paste/pr on one file twice. check-openro types the shell rows
# (dd is a build tool, staged into a COPY of the play image);
# check-openro-k is the generated kernel probe (fork, the error
# codes, group park/unpark under pool pressure).
check-openro: play-image $(BUILD)/dd.bin $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_openro.py

check-openro-k: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_openro_k.py

# check-openrw2 / check-openrw2-k (docs/OPEN-RW-2.md): ONE writer joins
# a read-intent shared group, so a reader and a writer hold one file at
# once. check-openrw2 types the shell rows; check-openrw2-k is the
# generated kernel probe (slot orders, truncation under readers, close
# ownership with a faulted FLUSH/CLOSE, park, fork/dup, spawn, K_ROOWN).
# Teeth: scripts/teeth_openrw2.py.
check-openrw2: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_openrw2.py

check-openrw2-k: play-image $(BUILD)/true.bin $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_openrw2_k.py

# check-oappend (docs/OAPPEND-1.md): per-write O_APPEND. OPEN_APPEND
# ($23) declares append intent; the kernel seeks to EOF before every
# WRITE / SET_EOF of such an entry, so any number of appenders may
# share a file. A generated probe drives the kernel (the
# check-openrw2-k machinery). Teeth: scripts/teeth_oappend.py.
check-oappend: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_oappend.py

# check-oappend-sh: the same, as the shell sees it -- two background
# `>>` appenders, `exec 3>>F 4>>F`, tee -a, nohup, `tail -f` beside
# two appenders, a no-intent writer beside an appender (both orders),
# `>> /dev/null`. Teeth: scripts/teeth_oappend.py (S*).
check-oappend-sh: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_oappend_sh.py

# check-open-census (docs/OPEN-RW-2.md item 6): every SC_OPEN call site
# in src/bin and src/liba is classified read-intent / no-intent in
# scripts/open_census.txt, and the classification matches the parmlist.
check-open-census:
	python3 $(SCRIPTS)/check_open_census.py

# check-encoding-census (docs/ENCODING-CENSUS-NOTES.md): every program
# (Makefile UTILS plus unput src/bin manifests) is classified covered /
# exempt / gap against foreign low-ASCII text in scripts/encoding_census.txt;
# a program with no line, a stale line or a covered claim with no
# check_encoding.py row is red.  Static (no emulator).
check-encoding-census:
	python3 $(SCRIPTS)/check_encoding_census.py





check-truefalse: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_truefalse.py

# vi through a shell-out (scripts/check_vi_bang.py): `:!cmd` shows the
# child's output and vi stays alive, `:%!sort` filters the buffer, and
# a SIGTERM-killed vi leaves the console cooked (PRC_TMD_RST). The
# coverage hole that let the ED_DISPATCH1 stack leak ship (2026-09-07).
check-vi-bang: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_vi_bang.py

# vi's alternate screen (scripts/check_vi_alt.py; docs/VI-ALTSCREEN.md):
# `ESC [ ? 1049 h/l` parks and restores the shell screen around vi on
# all three console backends, a KILLED vi is restored by the kernel
# backstop (PRC_ALT_RST), and unknown `?` private modes are silent.
check-vi-alt: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_vi_alt.py

# ^C aims at the console's declared FOREGROUND JOB (scripts/
# check_jobctl_a.py; docs/JOB-CONTROL.md Increment A): a `&` job
# survives the ^C that kills the foreground pipeline, a `sh SCRIPT` job
# dies whole (the declared pid's subtree), and ^C at the idle prompt
# kills nothing. RED on the global depth>=3 sweep.
check-jobctl-a: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_jobctl_a.py

# The suspend core at the SYSCALL level (scripts/check_jobctl_b.py;
# docs/JOB-CONTROL.md Increment B): src/test/jctest.s -- a gate-only
# program, NOT a UTILS member -- is staged onto a play.po CLONE
# (build/jobctl.po, scripts/build_jobctl_image.py) and run from the real
# shell. ^Z stops its declared child (PCB_STOPPED + tty restored),
# SYS_CONT resumes it, SYS_WAITJOB reports {stopped} and polls, legacy
# SYS_WAIT refuses a stopped-only set, and a dying parent's stopped child
# is reaped with its bank. RED on faad254 (no PCB_STOPPED, no call 19).
JCTESTBIN        := $(BUILD)/jctest.bin
JOBCTLIMAGE      := $(BUILD)/jobctl.po
$(JCTESTBIN): $(SRC)/test/jctest.s $(LIBA_SRCS) $(MEMMAP_ALL) $(SYSCALL_ALL) | $(BUILD)
	$(MERLIN32) $(SRC)/test/jctest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }

jobctl-image: play-image $(JCTESTBIN) $(SCRIPTS)/build_jobctl_image.py
	python3 $(SCRIPTS)/build_jobctl_image.py

check-jobctl-b: jobctl-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_jobctl_b.py

# The shell half of job control (scripts/check_jobctl_c.py; docs/
# JOB-CONTROL.md Increment C): at the real shell's prompt on play.po,
# ^Z parks `[n]+ Stopped   cmd`, `jobs` lists it, `fg` resumes it to
# completion, `bg` runs it on without the console, a finished `&` job
# is reported `[n]  Done   cmd` at the next prompt, and a bad `%n` is
# refused. RED on dc19977 (no job table: ^Z just reprompts, `jobs` is
# command-not-found).
check-jobctl-c: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_jobctl_c.py

# PERSON-LIKE end-to-end terminal + vi tests (docs/E2E-TERM.md): drive
# the machine one key at a time, the guest free-running a jittered slice
# between keys, asserting on what is actually RENDERED and ECHOED, on
# every console backend (40-col, native-80, UltraTerm). This is the
# oracle the burst-and-step harnesses could not be -- it models a person
# at the keyboard, so it catches echo/timing bugs those miss and does
# not manufacture the false positives they do. IN the sweep: on the box
# (where sweeps run) all three backends finish in ~36 s; a LOCAL
# check-all-cross including it is slower (person-scale timing), but local
# full sweeps are discouraged anyway. Standalone: `sh scripts/box_gate.sh
# check-e2e-term`.
check-e2e-term: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/e2e_vi_term.py all

# ---------------------------------------------------------------------------
# RECORDER (docs/RECORDER.md, docs/SITE.md sec 3): demos as code.
# site/demos/NAME.py is one script that runs two ways. Here it is a GATE
# (scripts/demo_record.py, gate mode: say/hold/fast are no-ops, the
# expect_* calls are the assertions, no screen_image, no ffmpeg), so a
# filmed demo fails in the sweep before anyone films it broken. Each
# demo gets its own check-demo-NAME so a red one names itself; the
# static pattern rule builds them from the files in site/demos/, and
# check-demos is all of them. Every demo mounts its own copy-on-write
# copy of play.po (boot() passes copy:true), so none writes the shared
# image; naming play-image puts them in sweep_par's serial play lane,
# which costs seconds.
#
# check-recorder is the recorder's own gate: record mode with
# --no-encode, so it needs no ffmpeg and runs on the box. `make demos`
# is record mode with the encoder: Mac and release time only, NOT in
# any sweep, it needs ffmpeg. It checks for ffmpeg BEFORE it builds the
# image (demo_record.py --check-ffmpeg names what is missing), and ends
# with check_recorder.py --ffmpeg-only: the host's own ffmpeg decodes one
# real screen_image frame, the cross-check the sweep must not make (the
# box has no ffmpeg, and a gate has to be the same on every host).
# ---------------------------------------------------------------------------
DEMOS      := $(patsubst site/demos/%.py,%,$(wildcard site/demos/*.py))
DEMO_GATES := $(addprefix check-demo-,$(DEMOS))

.PHONY: check-demos check-recorder demos $(DEMO_GATES)

# The extra boot disks some demos film on, each play.po plus one
# declared addition (scripts/build_demo_images.py): demo-unpack-image
# (a real ShrinkIt archive to unpack), demo-loop-image (a disk image
# to mount), demo-fed-image (the Federalist Papers) and
# demo-ddshrink-image (dd, a 1990 disk archive, and the floppy for
# slot 6). They are named *-image so sweep_par.sh pre-builds them
# before it fans out, PHONY like play-image and full-image (they are
# built FROM play.po, which is rebuilt every time), and published by
# imglock (flock + atomic rename), so two lanes queue instead of
# colliding. Their other prerequisites are what they are built from.
DEMO_IMAGES := demo-unpack-image demo-loop-image demo-fed-image \
               demo-ddshrink-image
.PHONY: $(DEMO_IMAGES)
demo-unpack-image: play-image fixtures/asimov/VBLSET.SHK \
                   $(SCRIPTS)/build_demo_images.py $(SCRIPTS)/imglock.py
	python3 $(SCRIPTS)/build_demo_images.py unpack
demo-loop-image: play-image $(SCRIPTS)/build_demo_images.py \
                 $(SCRIPTS)/loop_fix.py $(SCRIPTS)/imglock.py
	python3 $(SCRIPTS)/build_demo_images.py loop
demo-ddshrink-image: play-image $(BUILD)/dd.bin fixtures/gem/DEMOPROG.SDK \
                     $(SCRIPTS)/build_demo_images.py $(SCRIPTS)/imglock.py
	python3 $(SCRIPTS)/build_demo_images.py ddshrink
demo-fed-image: play-image $(wildcard fixtures/federalist/NO.*) \
                $(SCRIPTS)/build_demo_images.py $(SCRIPTS)/imglock.py
	python3 $(SCRIPTS)/build_demo_images.py fed

# play-image stays named DIRECTLY on check-demos and on every
# check-demo-NAME: sweep_par.sh (the playgates awk) keys on it to keep
# them in the serial play.po lane.
# hello (W15) films on the release disk, which has nas, ld, make and
# liba: full.po, built from play.po (hence play-image stays named). It
# uses none of the demo-*-image additions, so it does not wait for them.
# The list is DERIVED from the demos' own image= declaration, not
# typed: a typed one has to be edited by whoever adds a full-disk demo,
# and a demo left off it would silently gate against a STALE full.po
# (nothing names full-image for it, but demo_stamp.IMAGES still mounts
# it). check-site holds the two in agreement either way.
DEMO_FULL_GATES := $(addprefix check-demo-,\
                   $(patsubst site/demos/%.py,%,\
                   $(shell grep -l "image='full'" site/demos/*.py)))
$(filter-out $(DEMO_FULL_GATES),$(DEMO_GATES)): check-demo-%: play-image $(DEMO_IMAGES) $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/demo_record.py site/demos/$*.py
$(DEMO_FULL_GATES): check-demo-%: play-image full-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/demo_record.py site/demos/$*.py

check-demos: play-image full-image $(DEMO_IMAGES) $(DEMO_GATES)

check-recorder: play-image demo-ddshrink-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_recorder.py


demos: $(MCP_SUPERVISOR)
	$(MAKE) check-ut-render
	python3 $(SCRIPTS)/demo_record.py --check-ffmpeg
	$(MAKE) play-image full-image $(DEMO_IMAGES)
	python3 $(SCRIPTS)/demo_record.py $(wildcard site/demos/*.py) --record build/demos
	python3 $(SCRIPTS)/check_recorder.py --ffmpeg-only

# ---------------------------------------------------------------------------
# The website (docs/SITE.md sec 7, docs/SITEGEN.md, site/README).
# `make site` renders build/site/ from site/pages, docs/man (through
# $(MANDOC)), the demos and whatever videos build/demos holds; it needs no
# image and no emulator. `make site-serve` serves it on 127.0.0.1 (override
# SITE_PORT) for a look in a browser before anything ships. `make check-site`
# builds, then fails on a broken link, a placeholder with no fact, a fact
# with no source, a demo page with no demo, non-ASCII in site/, a link to
# cornflower.au, or a src comment naming a file that is not there; it first
# plants each of those in a scratch copy and requires it to go red.
# The /learn/ lesson pages include the sessions `make check-examples`
# wrote (see there); SITE_FLAGS=--skip-lessons builds without them.
# Settings: SITE_FLAGS='--apple2ts-url URL --image-url URL --repo-url URL'.
# ---------------------------------------------------------------------------
SITE_PORT  ?= 8000
# UT=1 publishes the UltraTerm films and the display selector, and is
# the default since cf683204: SH-DEFECTS item 9 (the console programmed
# a 16-line cell the glyphs did not fill) is fixed -- UT_INIT copies the
# card's own format-4 CRTC entry from $CF55 -- and the films were
# re-recorded on the operator's original v1 card (52f08954). UT=0 builds
# the //e's films alone. A sweep host needs the v1 ROMs for the ut rows;
# see SH-DEFECTS item 9's provisioning note.
UT ?= 1
UTFLAG = $(if $(filter 1,$(UT)),--ut)
SITE_FLAGS ?=
.PHONY: site site-serve check-site
site:
	python3 site/build.py $(SITE_FLAGS) $(UTFLAG)

site-serve: site
	@echo "serving build/site on http://127.0.0.1:$(SITE_PORT)/ (^C stops)"
	cd build/site && python3 -m http.server $(SITE_PORT) --bind 127.0.0.1

check-site:
	python3 $(SCRIPTS)/check_site.py $(UTFLAG)

# check-sessions-fresh: the cheap half of check-site's "stale session" rule,
# in preflight and check-all-host. A `make play` (or any full-image rebuild)
# changes build/full.po and stales every lesson page at once; check-site says
# so but is a full scratch build in no sweep. This hashes the image and reads
# the session headers (<1 s); nothing to compare passes. Remedy: make
# check-examples demos.
#
# IN preflight ONLY, deliberately -- NOT in CHECK_ALL_SEQ and not in
# CHECK_HOST_TARGETS. It compares a RECORDED sha against the image on
# disk, and a sweep REBUILDS that image and re-records the sessions as
# it goes, so inside one this gate races whichever lane is doing that
# and reds on a tree that is merely mid-flight. Measured 2026-10-31:
# red in a 4-lane box sweep, green run directly on the same box
# seconds later (the box's own full.po hashes 699a5a4ef817, the Mac's
# b2572215d6ee -- the box builds its own). Its subject is a DEVELOPER's
# stale tree, which is exactly what preflight looks at and what a
# sweep, by rebuilding, does not have.
check-sessions-fresh:
	python3 $(SCRIPTS)/check_sessions_fresh.py --selftest

# GitHub Pages tree (docs/SITE-PAGES.md, docs/RELEASE.md "Publishing the
# site"). `make site-pages VERSION=X.Y.Z` assembles build/pages/ from
# dist/maux-X.Y.Z/ and PRINTS the publish commands; nothing here pushes.
# `make site-preview` builds the same tree from build/full.po plus one zero
# block for a look before any tag exists; `make site-preview-serve` serves it
# on 127.0.0.1:$(PREVIEW_PORT) with CORS. PREVIEW_APPLE2TS names a local
# Apple2TS (e.g. http://127.0.0.1:5317/) instead of https://apple2ts.com/.
# DIST_ROOT names another bundle root (the refusal teeth plant one).
PREVIEW_PORT     ?= 8010
PREVIEW_APPLE2TS ?= https://apple2ts.com/
DIST_ROOT        ?= dist
.PHONY: site-pages site-preview site-preview-serve
site-pages:
	@test -n "$(VERSION)" || { echo "usage: make site-pages VERSION=X.Y.Z"; exit 2; }
	python3 $(SCRIPTS)/site_pages.py release --version $(VERSION) --dist-root $(DIST_ROOT) $(UTFLAG)

site-preview:
	python3 $(SCRIPTS)/site_pages.py preview --port $(PREVIEW_PORT) --apple2ts-url $(PREVIEW_APPLE2TS) $(UTFLAG)

site-preview-serve:
	python3 $(SCRIPTS)/serve_cors.py build/pages-preview $(PREVIEW_PORT)

# Cooperative ^Z: vi saves/restores the terminal across suspend
# (docs/JOB-CONTROL.md Increment E; SIG_TSTP catch + SYS_STOP + the
# ^Z sweep's disposition branch). At the real shell on play.po.
check-jobctl-e: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_jobctl_e.py

# BRE intervals \{n,m\} + \+/\? in the shared regex engine
# (scripts/check_regex.py; docs/REGEX-BRE-INTERVALS.md, ANACHRONISMS.md
# W5b). The forms a human types, through sed and one ed session at the
# play image's shell; hand-authored expectations because the host's BSD
# sed treats \+/\? as literal and so cannot oracle them. The
# host-differential half (\{n,m\} and the bare {+? literals, which the
# host DOES agree on) is in the e2e corpus (check-e2e).
check-regex: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_regex.py

# POSIX sed conformance gate (scripts/check_posixsed.py; docs/SED.md).
# The host's own sed is the oracle (BSD on the Mac, GNU on the box --
# the cases are restricted to constructs both agree on): every row's
# script travels as a -f FILE staged with a2til into /mnt/MAUX/PXSD on a
# copy of the play image, is run through maux's own shell with stdout
# redirected, and stdout + exit status + written files are compared
# byte-exact. check-sed stays the spawn-harness + arena-poison proof;
# this is the breadth.
check-posixsed: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_posixsed.py $(PLAYIMAGE)

# POSIX conformance gate for eleven small utilities (scripts/
# check_posixutil.py; docs/POSIX-GAPS.md sec 7): cat, cmp, comm, expr,
# head, grep, mkdir, pwd, sleep, true, false. Same method as
# check-posixsed -- every case's files staged with a2til into a FRESH
# per-case subdirectory of /mnt/MAUX/PXUT on a copy of the play image, run
# through maux's own shell, stdout + exit status (+ any named result
# file) compared BYTE-EXACT against the host's own binary. Where BSD/
# GNU cannot possibly oracle a row (a documented maux GAP, a 16-bit-
# only `expr`, or a ProDOS path with no host analogue) the expectation
# is hand-authored straight from the XCU spec text instead (`hand=` on
# the case, always with a `reason`). KNOWN_GAPS is a named, expected-red
# ledger (grep -E/-F/-f/multi -e, mkdir -m, expr's `:` and `()`, cat's
# -u and '-', head's -c) -- exit 0 requires every OTHER case to pass
# AND every KNOWN_GAPS case to still fail; a gap that starts passing is
# reported as an error, not silently absorbed.
check-posixutil: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_posixutil.py $(PLAYIMAGE)

# The POSIX regex test suites -- Glenn Fowler's AT&T corpus (the copies
# Go's regexp package carries) and Henry Spencer's (Tcl's reg.test) --
# run against the shared BRE engine through sed (scripts/check_fowler.py;
# docs/ANACHRONISMS.md W5d). A conformance REPORT with an exit status,
# not in CHECK_ALL_TARGETS: the corpora are spec-authored, so a red row
# is a real divergence to read, not a ratchet to keep. `vendor-fowler`
# fetches the four files (BSD/MIT-licensed test data; vendor/ is
# gitignored, same as the ProDOS and Merlin images).
FOWLER_DIR   := vendor/fowler
FOWLER_GO    := https://raw.githubusercontent.com/golang/go/master/src/regexp/testdata
FOWLER_TCL   := https://raw.githubusercontent.com/tcltk/tcl/main/tests
FOWLER_FILES := $(FOWLER_DIR)/basic.dat $(FOWLER_DIR)/nullsubexpr.dat \
                $(FOWLER_DIR)/repetition.dat $(FOWLER_DIR)/reg.test
# vendor-ftn: Apple's own File Type Notes, the reference for what every
# ProDOS file type and auxiliary type MEANS. Fetched rather than
# committed -- it is 532 KB of OCR and vendor/ is ignored.
#
# THIS IS OCR OF A SCAN AND IT MANGLES THE ONE CHARACTER THAT MATTERS:
# `$` reads as `S` throughout ("SOA DA3" is "$0A DA3"), and digits go
# with it ("pe' RPI" is "$11 RPI"). Never quote a grepped line from it
# without checking the page image. Details and the alternate scan are
# in learning:01M34341NAR4FXCB6G8K9VHBZ8's companion note.
FTN_IA  = Apple_II_File_Type_Notes_File_Type_Notes_DTS
FTN_DIR = vendor/ftn
vendor-ftn: $(FTN_DIR)/filetypenotes.txt
$(FTN_DIR)/filetypenotes.txt:
	@mkdir -p $(FTN_DIR)
	curl -sSfL -o $@ https://archive.org/download/$(FTN_IA)/$(FTN_IA)_djvu.txt

vendor-fowler: $(FOWLER_FILES)
$(FOWLER_DIR)/%.dat:
	@mkdir -p $(FOWLER_DIR)
	curl -sSfL -o $@ $(FOWLER_GO)/$*.dat
$(FOWLER_DIR)/reg.test:
	@mkdir -p $(FOWLER_DIR)
	curl -sSfL -o $@ $(FOWLER_TCL)/reg.test
check-fowler: play-image $(MCP_SUPERVISOR) $(FOWLER_FILES)
	python3 $(SCRIPTS)/check_fowler.py $(PLAYIMAGE)

# The POSIX scoreboard (`make check-posix`, scripts/posix_scoreboard.py):
# runs EVERY conformance suite -- check-posixutil, check-posixsed (gates),
# check-fowler, check-posixvi, check-posixex (reports) -- keeps each full
# log under build/posix/, and renders one table to build/posix/SCOREBOARD.md
# and the terminal. The suites are the project's record of what it is
# (operator, 2026-09-13), so this target is the one to run before writing
# any number down in docs/POSIX-CONFORMANCE.md. Not in CHECK_ALL_TARGETS
# (every suite it runs already is, or is a report by ruling): it exists
# to be read, not to ratchet.
check-posix: play-image $(MCP_SUPERVISOR) $(FOWLER_FILES)
	python3 $(SCRIPTS)/posix_scoreboard.py

# ---------------------------------------------------------------------------
# task #11: ProDOS MLI coexistence spike (docs/TASKS.md #11, docs/PRODOS-
# SPIKE.md). Vendored ProDOS 2.4 (never committed, vendor/ is gitignored --
# see scripts/vendor_prodos.py's header for the acquisition story) + a
# known-good SmartPort-bootable carrier volume (docs/PRODOS-SPIKE.md's
# rig-compatibility finding: a plain floppy-mastered ProDOS_2_4.dsk does
# NOT autoboot under verilogapple's mount_disk, which always presents a
# slot-7 SmartPort device).
# ---------------------------------------------------------------------------
# The spike used to set PRODOSBIN := here, GLOBALLY -- which silently
# overrode line ~107's `?=` default for every image in the tree for seven
# weeks (docs/PRODOS25-NOTES.md). The spike now has its own variable.
MLISPIKE_PRODOSBIN := $(shell pwd)/vendor/ProDOS-2.4.bin
MLISPIKEBLK    := $(BUILD)/MAUXSPIKE.SYSTEM
MLISPIKEIMAGE  := $(BUILD)/mli_spike.po

# check-carrier: the vendored carrier must match the lock BEFORE any image
# is built from it (2026-10-11: a stale BASIC carrier in main's vendor/
# cost two engineers a morning; a2til's error named neither cause nor
# fix). One sha256; runs ahead of `image` and `play-image`, in
# check-all via check-volname's walk, and with a planted self-test.
check-carrier:
	python3 $(SCRIPTS)/check_carrier.py
	python3 $(SCRIPTS)/check_carrier.py --selftest

image play-image: check-carrier

vendor-prodos:
	PRODOS_RELEASE=2.5 python3 $(SCRIPTS)/vendor_prodos.py
	PRODOS_RELEASE=2.4 python3 $(SCRIPTS)/vendor_prodos.py

# Extract the public-domain Merlin-8 v2.59 sources (task #8, docs/SELFHOST.md).
# vendor/ is gitignored; scripts/vendor_merlin.py carries the acquisition URL,
# sha256, licensing provenance, and the STEPBYSTEP build order.
vendor-merlin:
	python3 $(SCRIPTS)/vendor_merlin.py

# Kernel module-boundary ratchet (docs/SELFHOST.md, tasks #8/#8a). Static, no
# emulator: merlin32 has no REL/ENT/EXT so the boundary cannot be validated by
# building. Keeps the tree REL-linkable as it grows.
check-modules:
	python3 $(SCRIPTS)/check_modules.py

# L6 cannot drift from Dave Schmenk's bytes (docs/SITE.md L6): host-only.
# play-image is named for the reason check-full's comment gives (full.po is
# composed from play.po): the gate reads the image back.
check-plasma-examples: play-image full-image $(HELLOPLA_CUT)
	python3 $(SCRIPTS)/check_plasma_examples.py

# check-ascii: HACKING.md's tree-wide ASCII rule, which nothing enforced
# until 2026-09-19 (check_man.py covered docs/man only). Static, host-only,
# under a second; roster is `git ls-files`, so a new file is covered as
# soon as it is tracked. Exemptions are a named dict in the script.
check-ascii:
	python3 $(SCRIPTS)/check_ascii.py

# check-publish: what ships to the PUBLIC repo and what does not. The
# house Forgejo is LAN-only, so the tree is readable there; GitHub gets
# one squashed commit per release tag, which is why only file CONTENTS
# matter here and commit messages do not. Static, host-only, a few
# seconds. Its roster is `git ls-files` and there is NO fallback -- the
# tracked set is the whole subject of the gate, so it refuses to guess
# at it (see tracked() and the CHECK_BOX_TARGETS filter-out for why the
# box does not run it). The rules, the two leaks pinned BY NAME and
# their named triggers are all in the script's header.
check-publish:
	python3 $(SCRIPTS)/check_publish.py

# check-teeth-lib (HYG-4): the self-test of scripts/teeth_lib.py, the one
# sabotage runner behind every scripts/teeth_*.py. In-process, no
# emulator, no build, under 2 s: planted specs that MUST make the runner
# fail (an always-green gate, a named row green, an unobservable control,
# a stale or comment-only pattern, a timeout, a restore that drifts ...)
# and one good spec that must pass. In preflight (docs/HYG-4-NOTES.md
# sec 5.8).
check-teeth-lib:
	python3 $(SCRIPTS)/teeth_lib.py --selftest

# check-teeth-patterns (HYG-4): `--dry` on every teeth runner -- STATIC:
# every edit pattern still occurs exactly as often as the spec says, its
# span holds code and not only a comment, the schema is well formed. No
# build, no gate, no emulator. In CHECK_ALL_TARGETS (the sweep) and NOT in
# preflight: a refactor that stales another stream's teeth must retarget
# them before it lands (prove-the-teeth), but must not slow preflight.
check-teeth-patterns:
	python3 $(SCRIPTS)/check_teeth_patterns.py --selftest
	python3 $(SCRIPTS)/check_teeth_patterns.py

# check-prodos-version: every built image boots the ProDOS the ruling
# names (2.4). Host-side, a2til reads the PRODOS banner off each image;
# self-tests its own teeth on the vendored 2.4 and 2.5 disks first.
# Runs late in check-all so the image targets have been built.
check-prodos-version:
	python3 $(SCRIPTS)/check_prodos_version.py

# check-volname (docs/VROOT.md): no path literal naming the old boot
# volume (BASIC, slash-prefixed) in scripts/,
# src/, inc/, Makefile, docs/man or the live docs, and the volume on
# every built maux boot image is MAUX (check_prodos_version's own walk).
# Late in check-all, like check-prodos-version, for the same reason.
check-volname:
	python3 $(SCRIPTS)/check_volname.py

# check-doctruth (DOC-TRUTH, 2026-10-26): four documented claims were found
# contradicting the code -- $( ) refusing pipelines, `set -x` as the only
# set option, a probed aux-bank list, "no timer programmed" for the
# Mockingboard. The gate derives each truth from the source (PRC_INIT's
# literals, SETUSAGE_MSG, SUB_GRAB's compares, TMR_INT_MB) and requires
# the prose to agree; static, host-only, with an in-memory mutation
# self-test that plants every stale claim and requires red.
check-doctruth:
	python3 $(SCRIPTS)/check_doctruth.py








# check-lsbig: ls lists a directory past the old 128-entry cap. The
# manual directory is 149 pages, which is how the operator found it.
# Teeth proven 2026-09-20 by putting LS_MAXENT back to 128.
check-lsbig: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_lsbig.py

# check-encoding: maux's text convention, DECLARED in one place and
# measured against the machine. Nothing else in this tree can see an
# encoding -- the differential harness masks `b & 0x7F` before every
# comparison -- so a half-finished migration writing volumes of mixed
# text passes the whole suite green. The source and staging counts are
# shrink-only ratchets; flipping the two declared constants is the
# migration's switch, and the machine probe is what stops the
# declaration drifting from what maux actually writes.
check-encoding: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_encoding.py

# check-cmdword (KFIX10 items 3-5): a command word with a slash is a
# path and is never PATH-searched (`./hello`, `dir/hello`, `../hello`,
# a missing `./nope` is 127), make finds a bare command on PATH the way
# `sh -c` would and says `make: NAME: not found` for a missing one, and
# make reads a Makefile in either text convention. Private copy of
# play.po; the rows pin the exact lines below each command's echo.
.PHONY: check-cmdword
check-cmdword: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_cmdword.py $(BUILD)/play.po

# check-chtyp: `chtyp` changes the ProDOS type and aux and NOTHING else.
# Every case asserts the WHOLE directory entry read back from the HOST,
# because SET_FILE_INFO writes the full block and a tool that sends
# zeros for the fields it did not mean to touch destroys them silently.
# Teeth proven three ways 2026-09-21; the script's header records why
# case 5 has to poison the parmlist first (SFIPARM is emitted TEXT, and
# a warm respawn does not recopy text, so the first version of that
# case passed its own sabotage).
check-chtyp: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_chtyp.py

# check-nulib2: `nulib2 -t` walks a real NuFX archive and agrees with
# a2til, a second independent implementation, on every record. Slice 1
# of docs/NUFX.md -- the parse, not the decompression.
check-nulib2: play-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_nulib2.py








# The kernel .SYSTEM image-size ratchet. SEPARATE from check-modules on
# purpose: it MEASURES BUILT ARTIFACTS, and check-modules is a static
# gate with no prerequisites that runs first in CHECK_ALL_TARGETS. Wired
# into check-modules it made a clean tree structurally RED -- all 27
# images reported missing before any target could build them, which is
# the stale-artifact class this stream exists to kill, inverted into
# "must already have artifacts". Found by T2's review 2026-08-23.
#
# It is placed LAST in CHECK_ALL_TARGETS so every image-building target
# has already run. It takes no `make` prerequisites deliberately -- 27
# explicit ones would duplicate a list the checker already derives, and
# a derived list is the whole point of this stream.
check-kernel-images:
	python3 $(SCRIPTS)/check_kernel_images.py

# docs/KLEDGER.md: the exact per-label ledger of the flat kernel image.
# scripts/kledger.py attributes every emitted byte of a merlin32 -v1
# listing to (module, global label, kind) and fails unless the sum is
# the image's size ON DISK; `make kledger` regenerates the committed
# table for MAUXPLAY (docs/KLEDGER-TABLE.md; `make kledger KLEDGER_IMAGE=X`
# prints another image's), and check-kledger refuses a stale table.
# Host-side like check-kernel-images: it measures built artifacts, so it
# has no make prerequisites and runs after the image builders. It reads
# the build/*.SYSTEM_Output.txt listings, so sweep_par.sh groups it
# with the other listing readers (SWEEP_GROUPS).
KLEDGER_IMAGE ?= MAUXPLAY
kledger:
	@if [ "$(KLEDGER_IMAGE)" = MAUXPLAY ]; then \
	  python3 $(SCRIPTS)/kledger.py --image MAUXPLAY --write docs/KLEDGER-TABLE.md; \
	else python3 $(SCRIPTS)/kledger.py --image $(KLEDGER_IMAGE) --top 30; fi

check-kledger:
	python3 $(SCRIPTS)/check_kledger.py

# ---------------------------------------------------------------------------
# stream T2 (docs/STICKY.md sec PLACEHOLDER): the DERIVED poison-roster gate.
# Of the 32 `src/bin` programs whose storage lives in an uncleared `dum`
# arena, only 6 (cat/du/find/ls/sed/sh) have a gate that fills that arena
# with $A5 and proves write-before-read -- scripts/check_poison.py derives
# both numbers from source (never hardcodes them) and fails if a converted
# program with no poisoning gate is not held open in its own POISON_DEBT
# ratchet. Static, like check-modules -- no emulator, no merlin32, so it
# needs no prior build.
check-poison:
	python3 $(SCRIPTS)/check_poison.py

# Kernel scratch-home ratchet (docs/KSPACE-NOTES.md): static, no emulator.
check-kbss:
	python3 $(SCRIPTS)/check_kbss.py
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------

# Task #8 spike (docs/SELFHOST.md): prove Merlin's assembler core is reachable
# at the fixed vector ASMBLER=$$E5F3 headless, so `as` can be a shim. Needs
# `make vendor-merlin` first (vendor/ is gitignored).
check-asmspike: $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_asmspike.py

# Task #8a regression gate (docs/REL-LIBA-SPIKE.md): Merlin's linker includes
# WHOLE modules, so liba must be many small REL modules. Sources live in
# src/relspike/ and reach the image via `a2til mirror`.
REL_SOURCES := $(wildcard $(SRC)/relspike/*)

rel-image: $(REL_SOURCES)
	python3 $(SCRIPTS)/build_rel_image.py

check-rel: rel-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_rel.py

# Task #7: work disk for rebuilding Merlin from its own public-domain source
# with no interactive input (KBD prompts -> constants, PARMS suppresses the
# editor's one runtime question). Needs `make vendor-merlin` first.
merlin-src-image:
	python3 $(SCRIPTS)/build_merlin_src_image.py

# Task #7: rebuild Merlin from its own source unattended and byte-compare
# against the shipped binary. This is what lets REAL Merlin judge source.
check-merlin: merlin-src-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_merlin_build.py

# Task #8 phase B: work disk carrying the PATCHED `as`-core sources
# (vendor/merlin/ + src/merlin/patches.py overlay; vendor never modified).
# PHONY / rebuilt every run: check-ascore REPLACES the image's boot
# MERLIN.SYSTEM with the patched build, so a reused image would drive the
# patched (SAV-neutered) core through the rebuild and produce nothing.
# hardware variant (default) -- today's check-ascore group set, unchanged.
ascore-image:
	python3 $(SCRIPTS)/build_ascore_image.py --variant hardware

# process variant (task #8 phase C, docs/AS-DESIGN.md section 13): hardware
# set + P10, the RAMRD/RAMWRT-class removal `as.s` needs. Separate image/
# artifact names (ascore-process.po / ascore-process-*) so the two variants
# never collide -- see src/merlin/patches.py's HARDWARE_GROUPS/PROCESS_GROUPS.
ascore-process-image:
	python3 $(SCRIPTS)/build_ascore_image.py --variant process

# Task #8 phase B acceptance gate: rebuild the core FROM the patched
# sources (real Merlin, unattended), then prove the patched core
# assembles headless with a poison keypress latched, emits a
# byte-identical object, keeps its symtab in the main-bank window with
# aux untouched, ignores DSK, and diverges from vendor only at the named
# patch sites. See scripts/check_ascore.py's header for the phases and
# the vacuous-test guard. --variant defaults to hardware: this gate's
# meaning and its 6/6 teeth (scripts/teeth_ascore.py) are UNCHANGED by
# task #8 phase C's P10/two-artifact work.
check-ascore: ascore-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ascore.py --variant hardware

# The process core's own gate: same (d) divergence audit and real-Merlin
# rebuild as check-ascore, against the P1+P10 core, producing
# build/ascore-process-{merlin.system,as.obj,bank1.obj} -- but it does NOT
# drive (a)/(b)/(c)/(e) (those assert hardware-default RAMWRT behavior a
# bank-agnostic core doesn't share under MACED's own entry). check-as is
# the process core's behavioral proof, under its own maux-process entry.
check-ascore-process: ascore-process-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ascore.py --variant process

# warm variant (task #8 phase D, docs/STICKY.md sec 31's cure applied to
# `as`): IDENTICAL to process except SYMADR's value (src/merlin/
# patches.py's P1_SYMADR_HIGH vs P1_SYMADR_LOW) -- the symbol table
# lives above `as.s`'s own image end instead of inside it, so a warm
# respawn's un-recopied blob bytes can never overlap it. build_ascore_
# image.py's own --variant CLI choices do not cover `warm` (that file
# is out of this task's owned scope), so check_ascore.py's own
# --build-image flag calls that script's build() function directly with
# variant='warm' instead -- same underlying machinery, no edit to that
# file. `ld` keeps embedding the `process` artifacts above, unchanged.
ascore-warm-image:
	python3 $(SCRIPTS)/check_ascore.py --variant warm --build-image

# The warm core's own gate: same (d) divergence audit and real-Merlin
# rebuild as check-ascore-process, against the P1_SYMADR_HIGH core,
# producing build/ascore-warm-{merlin.system,as.obj,bank1.obj} -- but it
# does NOT drive (a)/(b)/(c)/(e) either, same reason as process. check-as
# is this core's own behavioral proof, under its own maux-process entry.
#
# It also compares the regenerated build/ascore-warm-{as,bank1}.obj with
# the tracked pins in pinned/ (the build tier's copies, DEPS-TIER): a
# patches.py change that moves one byte fails here with the re-pin line.
check-ascore-warm: ascore-warm-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_ascore.py --variant warm
	python3 $(SCRIPTS)/pinned.py compare

# ---------------------------------------------------------------------------
# Task #8 phase C/D (`make check-as`): src/bin/as.s runs the WARM core
# (P1w+P4+P5+P7+P10+P14, task #8 phase D's SYMADR-above-image cure,
# docs/STICKY.md sec 31 applied to `as` -- see src/merlin/patches.py's
# WARM_GROUPS) INSIDE maux. Deliverable 1's own artifacts:
#   build/as-stubs.bin        src/bin/asrom.s's P6 ROM stubs, assembled
#                             AT their real $FCA8-$FDF5 addresses (as.s
#                             copies them verbatim at startup -- see
#                             that file's header).
#   build/ascore-warm-*.obj   check-ascore-warm's own artifacts (the
#                             P1w+P10 bank-agnostic, SYMADR-above-image
#                             core, embedded via `putbin`) -- check-as
#                             depends on check-ascore-warm so they are
#                             always fresh. NOT build/ascore-*.obj (no
#                             P10) -- that pair is check-ascore's own
#                             hardware artifact. NOT build/ascore-
#                             process-*.obj either -- that pair is `ld`'s
#                             own embed (SYMADR=$2000, LINKER's own
#                             dictionary free ride) and must not move.
#   build/asmodtest.bin  merlin32 assembling src/test/asmodtest.s on the
#                        HOST -- the byte-identical-object reference
#                        (docs/AS-DESIGN.md section 0's milestone bar).
#                        No `dsk` directive in that source (kept identical
#                        to what gets staged for `as` itself to read) --
#                        merlin32 names the output after the source
#                        basename, renamed here.
# ---------------------------------------------------------------------------
$(BUILD)/as-stubs.bin: $(BINSRC)/asrom.s | $(BUILD)
	$(MERLIN32) $(BINSRC)/asrom.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }

# `| $(BUILD)` is load-bearing, not decoration: check_ascore.py writes
# straight into build/ and never creates it (no makedirs anywhere in
# the script). Without the order-only prerequisite this rule is the
# ONLY one in the file that can run before build/ exists, so a
# from-scratch tree fails here -- and it fails inside `as.bin`'s
# prerequisites, which makes it read as "check-userland needs an
# artifact a later gate produces" rather than as a missing mkdir.
# Two agents diagnosed it that way (2026-08-22) before anyone looked
# at the rule.
# AND THE IMAGE IT READS IS BUILT HERE TOO (2026-08-22). check_ascore.py
# consumes build/ascore-process.po and does not create it, so from a CLEAN
# build/ this rule failed with "ascore-process.po not found" -- and it
# fires from `as.bin`'s prerequisites, so the first casualties were
# check-userland/check-sh/check-shlang/check-play/check-play80/
# check-v1-system, six gates that have nothing to do with `as`. That is the
# same misreading the comment above records, one layer further out: the
# sweep only passed at all because an incremental tree already had the
# .obj files from a previous check-ascore-process run. `ascore-process-image`
# is PHONY (it must be), so the builder is invoked directly rather than
# named as a prerequisite -- exactly what that target's own recipe does.
# `ld.bin`'s own rule below still lists this SAME pair (ld must keep
# embedding the process/SYMADR=$2000 core) -- do not remove it.
# THE CORE ARTIFACTS DEPEND ON THE PATCH SOURCE, and said so only in
# prose until 2026-08-28. Both rules below carried an order-only `|
# $(BUILD)` and nothing else, so editing src/merlin/patches.py -- where
# every patched constant, SYMADR included, is spelled -- did NOT rebuild
# them, and `make build/as.bin` happily embedded a core built from the
# PREVIOUS patch set. That is not hypothetical: it cost most of a
# session. SYMADR was raised in as.s and in patches.py, the core was not
# rebuilt, so the symbol table went on being written at the old address,
# the arena went on being overwritten, and the (correct) diagnosis was
# discarded as refuted. check_ascore.check_symadr_agrees() compares the
# two SOURCE spellings and cannot see a stale ARTIFACT; make can, and
# now does. See docs/AS-PUT.md.
# Test tier only: real Merlin-8 rebuilds the core in the emulator, and unlike
# the warm pair this one is not pinned (only the `mld` and the dialect and
# stagebin gates use it; neither is on the play or release disk).
ifeq ($(MAUX_TIER),build)
$(BUILD)/ascore-process-as.obj $(BUILD)/ascore-process-bank1.obj:
	@echo "$@ needs the test tier (real Merlin in verilogapple); this tree was bootstrapped with TIER=build. check-dialect and check-stagebin are test-tier gates."; exit 2
else
$(BUILD)/ascore-process-as.obj $(BUILD)/ascore-process-bank1.obj: \
                  $(SRC)/merlin/patches.py \
                  $(SCRIPTS)/build_ascore_image.py \
                  $(SCRIPTS)/check_ascore.py | $(BUILD)
	python3 $(SCRIPTS)/build_ascore_image.py --variant process
	python3 $(SCRIPTS)/check_ascore.py --variant process
endif

# Same shape as the process rule above, warm variant, for `as.bin` alone
# (task #8 phase D). check_ascore.py's own --build-image flag stages the
# image (build_ascore_image.py's --variant CLI doesn't cover `warm`, see
# check-ascore-warm's own comment above), then the plain invocation
# rebuilds under real Merlin and extracts the artifacts.
#
# BUILD TIER (docs/DEPS-TIER.md): no emulator, so no real-Merlin run.
# The two objects are the tracked pins under pinned/, hash-locked in
# dependencies.lock.json; pinned.py verifies before it copies. The test
# tier regenerates them as above, and check-ascore-warm requires the
# regeneration to equal the pins.
ifeq ($(MAUX_TIER),build)
$(BUILD)/ascore-warm-%.obj: pinned/ascore-warm-%.obj \
                  dependencies.lock.json $(SCRIPTS)/pinned.py | $(BUILD)
	python3 $(SCRIPTS)/pinned.py copy build/ascore-warm-$*.obj
else
$(BUILD)/ascore-warm-as.obj $(BUILD)/ascore-warm-bank1.obj: \
                  $(SRC)/merlin/patches.py \
                  $(SCRIPTS)/build_ascore_image.py \
                  $(SCRIPTS)/check_ascore.py | $(BUILD)
	python3 $(SCRIPTS)/check_ascore.py --variant warm --build-image
	python3 $(SCRIPTS)/check_ascore.py --variant warm
endif

$(BUILD)/as.bin $(BUILD)/as.bin_Output.txt: $(BINSRC)/as.s \
                  $(BINSRC)/asboot.s $(BINSRC)/asxform.s \
                  $(BINSRC)/asdiag.s $(LIBA_SRCS) $(MEMMAP_ALL) \
                  $(SYSCALL_ALL) $(BUILD)/as-stubs.bin \
                  $(BUILD)/ascore-warm-as.obj \
                  $(BUILD)/ascore-warm-bank1.obj | $(BUILD)
	$(MERLIN32) -v1 $(BINSRC)/as.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }

$(BUILD)/asmodtest.bin: $(SRC)/test/asmodtest.s | $(BUILD)
	cd $(SRC)/test && $(MERLIN32) asmodtest.s
	mv $(SRC)/test/asmodtest $(BUILD)/asmodtest.bin
	@rm -f $(SRC)/test/_FileInformation.txt

# src/test/asputtest.s + asputinc.s -- the PUT case (docs/AS-PUT.md).
# merlin32 assembles the pair on the HOST with a relative put; the image
# stages the same pair with the put line rewritten to /mnt/MAUX/PUTINC.S,
# because that is the form a real staged unit carries. The two source
# texts therefore differ by one operand and must still produce the same
# OBJECT, which is the whole assertion.
$(BUILD)/asputtest.bin: $(SRC)/test/asputtest.s $(SRC)/test/asputinc.s \
                        | $(BUILD)
	cd $(SRC)/test && $(MERLIN32) asputtest.s
	mv $(SRC)/test/asputtest $(BUILD)/asputtest.bin
	@rm -f $(SRC)/test/_FileInformation.txt

# src/test/asmultitest.s -- multiple labels, a forward reference (NEXT),
# and a Merlin :LOCAL label (:loop) referenced backward in a loop
# (docs/AS-DESIGN.md section 10's own stress module for P9). check-as's
# byte-identical bar covers this too, not just the single-instruction
# GOODMOD.S -- a module this small could pass by accident.
$(BUILD)/asmultitest.bin: $(SRC)/test/asmultitest.s | $(BUILD)
	cd $(SRC)/test && $(MERLIN32) asmultitest.s
	mv $(SRC)/test/asmultitest $(BUILD)/asmultitest.bin
	@rm -f $(SRC)/test/_FileInformation.txt

# P11 proof module (docs/AS-DESIGN.md section 15/16, task #8 requirement
# 5): a source LARGER than as.s's OLD (pre-P11) achievable source-window
# capacity -- generated, not committed (scripts/gen_asbigmod.py's own
# header has the sizing arithmetic), so build/asbigmod.s is a build
# product like every other generated artifact here.
$(BUILD)/asbigmod.s: $(SCRIPTS)/gen_asbigmod.py | $(BUILD)
	python3 $(SCRIPTS)/gen_asbigmod.py

$(BUILD)/asbigmod.bin: $(BUILD)/asbigmod.s | $(BUILD)
	cd $(BUILD) && $(MERLIN32) asbigmod.s
	mv $(BUILD)/asbigmod $(BUILD)/asbigmod.bin
	@rm -f $(BUILD)/_FileInformation.txt

ASTESTBLK   := $(BUILD)/MAUXAS.SYSTEM
ASIMAGE     := $(BUILD)/as.po
ASTEST_DEPS := $(SRC)/test/astest.s $(SRC)/test/astestb.s \
                $(KERNEL_PROC_MODS)

$(ASTESTBLK): $(ASTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/astest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(ASTESTBLK) || { echo "missing $(ASTESTBLK)"; exit 1; }
	@test -f $(ASTESTBLK)_Output.txt || { echo "missing $(ASTESTBLK)_Output.txt"; exit 1; }

as-image: $(ASTESTBLK) $(BUILD)/as.bin $(BUILD)/sh.bin \
           $(SRC)/test/asmodtest.s $(SRC)/test/asbadmod.s \
           $(SRC)/test/asmultitest.s $(BUILD)/asbigmod.s
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_as_image.py

# ---------------------------------------------------------------------------
# THE S9 L5 MILESTONE ITSELF, and the only gate that runs it.
#
# One 32 MB ProDOS volume carrying maux, the userland, and all 208 source
# files of every unit's put closure staged RAW -- comments and all, because
# the point is that MAUX does the stripping. It boots, enumerates its own
# sources with `find`, WRITES ITS OWN STRIP SCRIPT with `sed`, runs it
# through `sh`, and assembles from the tree it just stripped. The invariant
# is byte-identity: /mnt/MAUX/ECHO.OBJ against merlin32's build/echo.bin.
#
# DELIBERATELY NOT IN check-all, and that is a real trade rather than an
# oversight: the run is ~40 minutes of Apple II time and minutes of wall
# clock even on the fast backend, against a sweep that has to stay runnable.
# The cost of that trade is that NOTHING ran this -- both scripts existed for
# two days with no target and no caller, so the milestone's own defining
# demonstration was a spike. A named target is the minimum: it can be run
# after any change that touches what maux strips or assembles, which is most
# of src/ and every include split.

check-selfhost: $(BUILD)/echo.bin $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/build_bigdisk_image.py
	python3 $(SCRIPTS)/run_selfhost.py

# The REL references (build/rtlib.rel + rtmain.rel + rel-meta.json)
# are real Merlin's own REL objects, exported by check_rel.py after
# its run -- merlin32 cannot produce Merlin-8 REL dictionaries (its
# `rel` output is GS/OS OMF), so this is the one reference in the
# tree that comes from the emulator rather than the host assembler.
# A file rule, not a PHONY dep: check-rel is a full emulator drive
# and only needs re-running when the references are missing (or when
# the spike sources change, which rel-image tracks).
$(BUILD)/rtlib.rel: $(SCRIPTS)/check_rel.py rel-image $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_rel.py

# check-as depends on BOTH check-ascore and check-ascore-warm (not just
# the .obj files) so a stale/half-built ascore*.po from a previous teeth
# run never silently feeds a wrong core into `as`'s own embed, and so
# the divergence audit runs fresh for BOTH artifacts every time
# (docs/AS-DESIGN.md section 13, ruling 2 -- "the divergence audit still
# covers both") even though only the warm core is embedded here. Task
# #8 phase D: was check-ascore-process (`as` embedded that core through
# 2026-08-23) -- swapped to check-ascore-warm now that `as.s` embeds the
# SYMADR-above-image variant instead; `make check-ld` still gates
# check-ascore-process on its own for `ld`'s sake.
check-as: check-ascore check-ascore-warm as-image $(BUILD)/asmodtest.bin \
           $(BUILD)/asmultitest.bin $(BUILD)/asbigmod.bin \
           $(BUILD)/asputtest.bin $(BUILD)/rtlib.rel $(MCP_SUPERVISOR)
	python3 $(SCRIPTS)/check_as.py

# ---------------------------------------------------------------------------
# task #8, next slice: `ld`, the linker front end (docs/LD-DESIGN.md).
# Same shape as as-image/check-as, with one addition build_as_image.py
# never needed: build_ld_image.py ALSO produces build/rtlinked.bin, the
# stock reference link output -- LINK has no host-side merlin32
# equivalent (docs/AS-DESIGN.md section 10's own dialect gaps), so the
# reference comes from booting real Merlin-8 under verilogapple and
# peeking the result, the same way scripts/check_rel.py already proves
# the stock answer (its own helpers are imported, not duplicated).
# ---------------------------------------------------------------------------
$(BUILD)/mld.bin: $(BINSRC)/mld.s $(LIBA_SRCS) $(BUILD)/as-stubs.bin \
                  $(BUILD)/ascore-process-as.obj \
                  $(BUILD)/ascore-process-bank1.obj | $(BUILD)
	$(MERLIN32) $(BINSRC)/mld.s
	@rm -f $(BINSRC)/_FileInformation.txt
	@test -f $@ || { echo "missing $@"; exit 1; }

LDTESTBLK   := $(BUILD)/LDTEST.SYSTEM
LDIMAGE     := $(BUILD)/ld.po
LDTEST_DEPS := $(SRC)/test/ldtest.s $(SRC)/test/ldtestb.s \
                $(KERNEL_PROC_MODS)

$(LDTESTBLK): $(LDTEST_DEPS) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/ldtest.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(LDTESTBLK) || { echo "missing $(LDTESTBLK)"; exit 1; }
	@test -f $(LDTESTBLK)_Output.txt || { echo "missing $(LDTESTBLK)_Output.txt"; exit 1; }

# PHONY (like mli-image): build_ld_image.py boots real Merlin-8 fresh
# every run to produce build/rtlinked.bin + the RTLIB/RTMAIN objects, so
# there is no single up-to-date-or-not artifact make can track cheaply.
ld-image: $(LDTESTBLK) $(BUILD)/ld.bin $(BUILD)/sh.bin $(MCP_SUPERVISOR)
	@test -f $(PRODOSBIN) || { echo "missing $(PRODOSBIN) -- run 'make vendor-prodos' first"; exit 1; }
	python3 $(SCRIPTS)/build_ld_image.py

# check-ld depends on check-ascore-process (not just the .obj files) for
# the same reason check-as does -- a stale core never silently feeds
# `ld`'s own embed, and the divergence audit (which now also covers
# LINKER.S, docs/AS-DESIGN.md section 17 / src/merlin/patches.py's P12
# group) runs fresh every time.
check-ld: check-ascore-process ld-image
	python3 $(SCRIPTS)/check_ld.py

$(MLISPIKEBLK): $(SRC)/test/prodos.spike.s $(SRC)/kernel/mli.s \
                 $(SRC)/kernel/mouse.s $(MEMMAP_ALL) $(EQU_KERNEL) | $(BUILD)
	$(MERLIN32) -v1 $(SRC)/test/prodos.spike.s
	@rm -f $(SRC)/test/_FileInformation.txt
	@test -f $(MLISPIKEBLK) || { echo "missing $(MLISPIKEBLK)"; exit 1; }
	@test -f $(MLISPIKEBLK)_Output.txt || { echo "missing $(MLISPIKEBLK)_Output.txt"; exit 1; }



clean:
	rm -rf $(BUILD)

# Prove a refactor emitted no different code:  make check-bytes REF=<commit>
# The artifact set is defined in the script, not here -- see its header for
# why that matters.
check-bytes:
	@test -n "$(REF)" || { echo "usage: make check-bytes REF=<commit>"; exit 2; }
	python3 $(SCRIPTS)/check_bytes.py REF=$(REF)

# Stage the maux tree on a ProDOS volume real Merlin can assemble from.
maux-src-image:
	python3 $(SCRIPTS)/build_maux_src_image.py

# Task #7: assemble the kernel with merlin32 AND with real Merlin-8, and
# require the two images to be byte-identical. See the script's header.
# PARKED 2026-09-12 (operator: "stop grinding against merlin-8. cross
# assemble it and get it done. we'll leave it to nas later."): NOT in
# CHECK_ALL_TARGETS. The VT102 console work's +36 kernel globals ran real
# Merlin-8's SYMBOL TABLE out ("Memory full in line", measured ceiling
# ~17.5 KB -- build_maux_src_image.py's per-unit symbol budget reports
# it). merlin32 is the assembler of record; the Merlin-8 byte-identity
# proof resumes under nas (docs/AS-PLASMA.md), which has no such table.
# The target still runs by hand on the leanest kernel manifest (DUAL =
# pipewraptest.s).
check-dual: merlin-src-image maux-src-image
	cd $(SRC)/test && merlin32 pipewraptest.s >/dev/null && rm -f _FileInformation.txt
	python3 $(SCRIPTS)/check_dual.py

# Task #7, the other half: the dialect INTERSECTION enforced statically
# over every compilation unit in the tree -- silent-divergence expression
# scan, dum placement, the 41215-byte source-buffer budget (set-ratchet,
# STRIPPED, over S9's remaining conversion debt -- review finding B1,
# 2026-08-23: measuring raw os.path.getsize() made the strip's payoff
# invisible), and the PARMS $83 assertion. No emulator; check-dual is
# the byte-identity instrument this scales out from. The budget's
# putbin->HEX/PUT modeling needs every real blob ld.s/as.s embed on
# disk -- same prerequisites check-as/check-ld already build. Stream T5
# split `as.s` onto its OWN pair (build/ascore-warm-{as,bank1}.obj,
# task #8 phase D's SYMADR-above-image cure) while `ld.s` kept
# build/ascore-process-{as,bank1}.obj -- five distinct blobs between
# the two units now, not three, and check_dialect.py's own
# _derive_putbin_prefixes() derives their flat-name prefixes from
# whichever ones the graph actually finds, but it still needs them ON
# DISK. `make check-dialect` builds all five rather than failing on a
# clean tree; a bare `python3 scripts/check_dialect.py` still fails
# loudly if any is missing, naming the fix.
check-dialect: $(BUILD)/as-stubs.bin $(BUILD)/ascore-process-as.obj \
               $(BUILD)/ascore-process-bank1.obj \
               $(BUILD)/ascore-warm-as.obj $(BUILD)/ascore-warm-bank1.obj
	python3 $(SCRIPTS)/check_dialect.py

# ld.s/as.s stage `putbin <blob>` (a merlin32-only directive real
# Merlin-8 2.59 does not have) into HEX-dump PUT files. Host-only, no
# emulator: round-trips every real embedded blob byte-exact, checks
# line-length/syntax properties, and computes the real per-unit budget
# (stripped manifest + use + largest put) against the 41215-byte
# source-buffer ceiling. check_stagebin.derive_putbin_blobs() reads
# whatever putbin targets the graph carries today (ld.s's
# ascore-process-{as,bank1}.obj AND, since stream T5, as.s's own
# ascore-warm-{as,bank1}.obj), so all five blobs -- plus the shared
# as-stubs.bin -- must be on disk; listed here so a clean tree builds
# them first instead of silently round-tripping a stale leftover from
# a previous build.
check-stagebin: $(BUILD)/as-stubs.bin $(BUILD)/ascore-process-as.obj \
                $(BUILD)/ascore-process-bank1.obj \
                $(BUILD)/ascore-warm-as.obj $(BUILD)/ascore-warm-bank1.obj
	python3 $(SCRIPTS)/check_stagebin.py

# strip_comments.py is the single rule for "blank out comment-only
# lines" (build_maux_src_image.py's staging, check_dialect.py's budget
# gate, and this gate's own differential all import it -- see its module
# docstring). Nothing ran its own --selftest until an adversarial review
# sabotaged the rule to column-0-only and found check-all fully green
# under a 93 KB regression: --selftest failed, but nothing invoked it,
# and check-dual stayed green because comments cannot change emitted
# bytes by construction. --selftest's ten synthetic cases plus tripwire
# run first; check_strip.py then differentials strip_text() against an
# INDEPENDENT regex implementation of the same operator spec over every
# file in check_manifests.universe() (byte for byte, line count
# preserved) and ratchets the measured blanked-line count against a
# floor, so a rule that quietly narrows shows up as a falling count.
check-strip:
	python3 $(SCRIPTS)/strip_comments.py --selftest
	python3 $(SCRIPTS)/check_strip.py

# Every gate, in one go. Two separate incidents on 2026-08-17 came from
# running a habitual SUBSET: check-memmap sat red for hours after a symbol
# rename, and `make image` does not build the process modules so it passed
# over a hard assembly error in procfd.s. A subset is not a check.
#
# check-bytes is excluded -- it needs a REF= to compare against, so it is not
# a standalone pass/fail. check-bankcopy-experiment is excluded as a spike.
# ORDER MATTERS in two places (2026-09-03, after five full passes in one
# day of which two were only to clear artifact reds):
#  * the self-host cluster generated REL modules and kernel-main segments
#    from the listings and .bin references that check-argv, check-fork,
#    check-expr, check-chmod, ... PRODUCE -- so it ran after every
#    image-building gate, else the first pass after any kernel edit was red
#    on stale listings and a second pass was needed to go green. Its three
#    legacy members (check-librel/librelas/relink) LEFT this list by the
#    2026-09-20 ruling; the ordering constraint still binds what remains,
#    check-nas-selfmake-image and check-kernel-images, so do not move those
#    above the image-building gates;
#  * check-ex is IN the list: check-kernel-images scans MAUXEXTEST.SYSTEM,
#    and nothing else rebuilds it, so without check-ex the size ratchet
#    reports a stale image after every kernel edit.
#: THE ORDER ABOVE IS THE SWEEP ORDER, and it lives here in ONE place:
#: CHECK_ALL_TARGETS is this sequence minus the gates whose recipes are
#: not in this tree (the ruling: NOT PUBLISHED: docs/PUBLISH-RIG-CUT.md).
#: CHECK_RIG_TARGETS names them (names only -- a
#: variable may name a target that does not exist), gates.mk carries
#: the recipes and sets MAUX_RIG, and a tree without gates.mk drops
#: them from the sweep instead of failing on a missing script.
CHECK_ALL_SEQ = check-deps check-deps-selftest check-sweep-par check-modules check-kbss check-ascii check-doctruth check-publish check-host-sweep check-plasma-examples check-teeth-patterns check-lc check-man-image check-poison check-altzp check-memmap check-boot check-probe \
                    check-sched check-syscall check-bankcopy check-userland \
                    check-process check-fileprocess check-mli check-apple2ts check-catread \
                    check-pipewrap check-bufio check-lc-prodos check-lcbank check-kseg check-init check-issue check-lazyvc check-lazyinval check-lsbig check-shutdown check-bye check-oftbye check-ramdis check-ramworks-reset check-rambye check-chtyp check-encoding check-nulib2 check-tenant \
                    check-sh check-shlang check-env check-cmdword \
                    check-ed check-ex check-iobuf check-ibf-ceiling check-openro check-openro-k check-wake check-sleep check-wait check-reset check-truefalse check-play check-v1-system check-rel \
                    check-ultraterm check-play80 check-play80n check-ut-bold check-more check-spawnfail check-vc \
                    check-vi check-vi-bang check-vi-alt check-ildl check-vt102 check-intr check-typeahead check-shedit check-tabcomp check-dirtyram check-masked check-switch-writers check-jobctl-a check-jobctl-b \
                    check-jobctl-c check-jobctl-e \
                    check-proshim check-mlival check-dd check-partition check-devblk check-floppy check-devfs check-mount check-exec check-brk check-ps check-devpath check-shfd check-shprefix check-shnlvar check-shforeign check-shmlquote check-shexecloop check-shseq check-openrw check-openrw2 check-openrw2-k check-oappend check-oappend-sh check-open-census check-encoding-census check-loop check-lseg check-df check-unpack check-bpatch check-plasma check-plasm check-nas check-nas-rel check-nas-real check-nas-librel check-idle check-plascut \
                    check-glob \
                    check-argv check-fdact check-asmspike check-merlin check-ascore \
                    check-string \
                    check-ascore-process check-ascore-warm check-as \
                    check-dialect check-stagebin check-strip \
                    check-sticky check-ls check-ld check-seek check-fleet \
                    check-testev check-tail check-nm \
                    check-find check-diff check-expr \
                    check-du check-comm check-sumdate check-chmod \
                    check-sed check-regex check-posixsed check-posixutil \
                    check-textaudit check-shwarm check-fork \
                    check-e2e-host check-e2e \
                    check-writefail-host check-writefail \
                    check-dirfull-host check-dirfull \
                    check-nas-selfmake-image check-nas-selfmake check-full check-plasm-full check-examples check-liba-pins \
                    check-kernel-images check-kledger \
                    check-e2e-fs-host check-e2e-fs \
                    check-e2e-term \
                    check-ser check-tip check-tip-vim check-release-pack \
                    check-demos check-recorder \
                    check-prodos-version check-volname

CHECK_RIG_TARGETS = \
                    check-boot check-probe check-sched \
                    check-syscall check-bankcopy check-process \
                    check-fileprocess check-mli check-apple2ts check-catread check-pipewrap \
                    check-lc-prodos check-lcbank check-kseg check-init \
                    check-issue \
                    check-lazyvc check-lazyinval check-shutdown check-bye \
                    check-oftbye check-ramdis check-ramworks-reset \
                    check-rambye check-tenant check-ibf-ceiling check-wake \
                    check-sleep check-wait check-reset check-ultraterm \
                    check-play80 check-play80n check-ut-bold check-vc \
                    check-ildl check-vt102 check-intr check-typeahead \
                    check-dirtyram check-masked check-switch-writers \
                    check-proshim check-mlival check-partition check-devblk \
                    check-floppy check-devfs check-mount check-exec \
                    check-brk check-devpath check-loop check-idle \
                    check-sticky check-fork check-writefail check-dirfull \
                    check-ser check-tip check-tip-vim

CHECK_ALL_TARGETS = $(if $(MAUX_RIG),$(CHECK_ALL_SEQ),\
                      $(filter-out $(CHECK_RIG_TARGETS),$(CHECK_ALL_SEQ)))

# check-e2e-fs (the EMULATOR half) IS in check-all as of 2026-08-24.
# It runs all 131 cases in ~10s and passes: 125 agree with their
# declared oracle, 6 are pinned to a KNOWN DEFECT, 0 are withheld.
#
# It was parked for days behind what this comment used to describe as
# a CREATE+OPEN hang, with three dead theories listed under it. The
# fingerprint did not survive measurement and none of the theories was
# the cause. It was TWO stacked bugs, neither in maux's kernel:
#
#   1. a2til wrote every subdirectory header's parent_entry_number
#      0-based where ProDOS reads it 1-based (filed as a2til#16, fixed
#      upstream). Real ProDOS walking up from a subdirectory landed one
#      entry early -- on the directory HEADER when that subdirectory
#      was its parent's first entry -- read two header bytes as a block
#      number, and retried the resulting out-of-range write forever.
#      That is where 15846 came from, the "sharpest clue" this comment
#      used to end on: the boot block parsed as a directory. `rm` of a
#      file two levels deep hung; root and one level were fine, which
#      is exactly why the shape looked like CREATE+OPEN.
#   2. find/du's SKIPRESUME counted down CURRESN itself -- the level's
#      absolute position -- so any directory holding two or more
#      subdirectories made the walk re-descend into the first forever.
#
# Cost of having it in: ~10s, not the ~330s this comment budgeted for
# a run that could only fail. scripts/probe_rmhang.py reproduces the
# original hang in three boots if it is ever needed again.
# check-as is BACK IN check-all (task #8 phase C landed, docs/AS-DESIGN.md
# section 14): bug 4 (PUTBYT's RAMWRT) is fixed by the P10 class removal
# (a SEPARATE process core, not a shared-artifact patch -- the two-
# artifact split section 13 ruled), a zero-page collision between this
# file's own liba PTR1/PTR2 and the core's OBJPNT/OBLEN in as.s's own
# WRITEOBJ is fixed, and P9 -- found unnecessary once those were fixed --
# is dropped entirely. `make check-as` passes byte-identical for both a
# single-instruction module and src/test/asmultitest.s (multiple labels,
# forward reference, :LOCAL label), plus a nonzero exit and an "as: "
# diagnostic on a bad source. check-ascore-process and check-ascore-warm
# are included alongside it (not merely check-as/check-ld dependencies)
# so their own divergence audits are part of the sweep too.

# Gate logs live under THIS tree's build/, not /tmp. They used to be
# /tmp/maux-$t.log, a path shared by every worktree on the machine --
# so two agents sweeping at once silently overwrote each other's
# evidence. That voided two sweeps on 2026-08-22, and the second one
# was diagnosed only because a log mentioned symbols absent from the
# tree that was reading it. A gate log naming the wrong tree is worse
# than no log: it is evidence for a run that never happened.
CHECKLOGDIR := $(BUILD)/checklogs

# `make preflight` (RULINGS-1 F13, 2026-10-18): the static gates that
# went red most often at the START of a sweep, run first, locally, in
# ~30 s, so a sweep never spends minutes to learn what a few seconds
# could have said. Measured over a week: 19 of 39 box sweeps red, 215
# box-minutes, commonest cause check-kledger (docs/KLEDGER-TABLE.md not
# regenerated), then check-encoding, check-modules, check-dialect. NOT in
# CHECK_ALL_TARGETS (every one of them is already in the sweep); it is
# the sweep's front door: scripts/box_gate.sh runs it before the rsync
# of a full sweep and aborts on red, and check-all-cross-par depends on it.
# The kledger step REGENERATES the table and then asks git: a table that
# differs from HEAD afterwards is a stale commit, said in one line. Its
# FIRST step (before play-image can touch anything) demands that
# `git status --porcelain` be empty: no uncommitted change to a tracked
# file and no untracked file that is not ignored. That is exactly what
# "swept at SHA X" can claim. It is NOT the whole tree rsync ships:
# ignored paths that box_gate.sh does not exclude (vendor/, .deps/,
# dist/) travel too and are not checked.
# check-kernel-images needs every kernel image built and current, so the
# derived image set is built first (`check_kernel_images.py --targets`).
preflight:
	@if [ -n "$$(git status --porcelain)" ]; then \
	  echo "preflight: the working tree has uncommitted changes (tracked, or untracked and not ignored). rsync ships the tree, so commit first:"; \
	  git --no-pager status --short | head -20; exit 1; fi
	@$(MAKE) --no-print-directory play-image
	python3 $(SCRIPTS)/kledger.py --image MAUXPLAY --write docs/KLEDGER-TABLE.md
	@if [ -n "$$(git status --porcelain -- docs/KLEDGER-TABLE.md)" ]; then \
	  echo "preflight: regenerate and commit docs/KLEDGER-TABLE.md (the table in HEAD is stale; 'make kledger' just rewrote it)"; \
	  git --no-pager diff --stat -- docs/KLEDGER-TABLE.md; exit 1; fi
	@$(MAKE) --no-print-directory check-kledger check-encoding check-modules check-dialect check-ascii check-doctruth check-publish check-host-sweep check-kbss check-teeth-lib check-sessions-fresh
	@$(MAKE) --no-print-directory $$(python3 $(SCRIPTS)/check_kernel_images.py --targets)
	@$(MAKE) --no-print-directory check-kernel-images
	@echo "preflight: PASS (kledger, encoding, modules, dialect, ascii, doctruth, publish, host-sweep, kbss, teeth-lib, sessions-fresh, kernel-images)"
check-all-cross-par: preflight

# `make check-all-cross` -- historically this was check-all minus the three
# legacy as/REL gates (check-librel, check-librelas, check-relink). OPERATOR
# RULING 2026-09-20 retired those three from check-all itself, so the two
# lists are now IDENTICAL and this name is kept only so existing scripts,
# docs and muscle memory keep working.
#
# WHY THEY WERE RETIRED. All three failed on nothing but the SUPERSEDED
# assembler's source window: ten kernel/regex modules exceed real Merlin-8's
# 41,215-byte buffer (worst, KTTY at 50,692) and REGEX exceeds `as`'s
# 16,126-byte budget. nas+ld is the path of record; Merlin-8 was retired as
# the build assembler by the 2026-09-08 ruling. Keeping them as blockers
# priced every kernel edit at a mechanical module split -- the coupling cost
# PROJECT-STATE.md sec 6 names as an architectural risk -- to defend a
# capability the project had already given up.
#
# WHAT IS LOST, said plainly: nothing now asserts that real Merlin-8 could
# assemble the WHOLE KERNEL from staged source. That claim is dead and should
# not be made. What `as` is still for -- a person assembling a module at the
# machine -- stays gated and is stronger than a capacity model: check-as runs
# `as` INSIDE maux over four modules and requires objects byte-identical to
# merlin32's, including build/asbigmod.s at 16,127 B, the exact maximum its
# window admits (16,128 proven to fail, bracketed 2026-08-29). check-ascore,
# check-ascore-warm, check-stagebin and check-strip stay in as well.
#
# RETIRED 2026-10-18 (RULINGS-1, operator ruling): the three targets are
# GONE, with check-selfmake (the Merlin-window self-make, red outside the
# sweep since KFIX4) and their dedicated image builder and drivers. They
# were callable for historical work for a month and nobody called them;
# check-nas-selfmake (in the sweep) is the replacement. History lives in
# docs/KFIX4-NOTES.md sec 3, docs/VERIFICATION.md and
# evidence/sweep-828309c-2026-09-18/README.md.
CHECK_CROSS_TARGETS = $(CHECK_ALL_TARGETS)

# `make check-all-box` -- check-all-cross minus the three gates whose
# ORACLE is the Mac, for the Linux emulator box (scripts/box_gate.sh,
# verilogapple#18): check-boot needs the rtl tier the box is built
# without (Verilator), and the two differential e2e gates compare
# against BSD coreutils -- maux mirrors V7/BSD forms, and on a GNU host
# cmp's wording/-l format and ls's exit 2 for a missing operand are a
# DIFFERENT oracle, not a better one (first box run 2026-09-05: those
# were the only reds). Their -host self-tests stay in. Run the three
# excluded gates on the Mac (~1 min) before a merge.
# check-posixutil joined this list 2026-09-20, for the SAME reason as
# check-e2e/check-e2e-fs and confirmed on both hosts rather than assumed:
# its oracle is the host's own utilities, and BSD `ls -R` omits the
# top-level directory header while GNU `ls -R` prints it. maux mirrors
# the V7/BSD form by ruling, so on the box that one case diverges from a
# DIFFERENT oracle, not a better one. The other 557 cases are hostable;
# splitting them is worth doing the day this list grows again.
# check-tip-vim was out of this list 2026-10-20 to 2026-10-21 (HYG-1): on
# the box (Debian vim 9.0.1378) it FAILED at "j x30" while the Mac (vim
# 9.1) passed. PACE-1 found why (docs/PACE-1-NOTES.md sec 0d): vim 9.0
# clears IXON on its pty, so the guest's own XON ($11, sent when the SSC
# ring drains) reached vim as CTRL-Q, blockwise Visual mode, and the
# reverse-video highlight left an inverse `l` in column 0 of every row.
# The gate now restores IXON on the host pty (a host that honours
# XON/XOFF is what the driver is written to), so it is back on the box.
# check-publish joined this list 2026-10-29, for the same shape of
# reason: its ORACLE is the git index. "What ships to the public repo"
# IS the tracked set, and only git knows it. The box tree is rsynced
# from a worktree, so its `.git` is a POINTER FILE naming the Mac path
# -- `git ls-files` fails there. The gate used to fall back to a
# filesystem walk, which cannot tell a tracked file from a build
# artifact: on the box it counted 2918 files against the Mac's 2718 and
# reported the pointer file's own contents as a local-path leak (first
# box run of the gate, 2026-10-29, its only red). The fallback is gone
# and the gate now refuses to guess. Nothing is lost by excluding it:
# it is in `make preflight`, which box_gate.sh runs on the Mac BEFORE
# it syncs, so every box sweep has already passed it.
CHECK_BOX_TARGETS = $(filter-out check-deps check-boot check-e2e check-e2e-fs check-posixutil check-publish,$(CHECK_CROSS_TARGETS))

check-all-cross: SWEEP_TARGETS = $(CHECK_CROSS_TARGETS)
check-all-cross: SWEEP_DONE = all cross-toolchain gates green (native cluster skipped)
check-all-box: SWEEP_TARGETS = $(CHECK_BOX_TARGETS)
check-all-box: SWEEP_DONE = all box gates green (check-boot/check-e2e/check-e2e-fs/check-posixutil/check-publish: run on the Mac)
# Parallel sweeps: the same target lists, N gates in flight (see
# scripts/sweep_par.sh's header for what made this safe). J defaults
# to 4; the box has 16 cores and 8 GB, and each gate is one emulator.
J ?= 4
check-all-box-par: SWEEP_TARGETS = $(CHECK_BOX_TARGETS)
check-all-cross-par: SWEEP_TARGETS = $(CHECK_CROSS_TARGETS)
# SWEEP_SH: the parallel driver needs a POSIX shell that word-splits AND is
# not bash 3.2. Found 2026-09-20: invoked as `sh`, which on macOS IS bash
# 3.2.57, scripts/sweep_par.sh exits 1 with NO DIAGNOSTIC AT ALL, for any
# target list, right after it captures the ~500 KB `make -pn` database --
# the worst failure shape there is, and the reason check-all-cross-par had
# never run on the Mac while docs/VERIFICATION.md recommended it. The
# mechanism in bash 3.2 is NOT explained: the same sequence reduced by hand
# runs fine there, `sh -n` reports no syntax error, and nothing is printed.
# Under bash 5 the driver runs correctly; under zsh it runs but collapses the
# whole target list into one word (zsh does not split unquoted $pool), so
# zsh is NOT a substitute. Override SWEEP_SH if your /bin/sh is modern.
SWEEP_SH ?= bash
check-all-box-par check-all-cross-par:
	@$(if $(MAUX_RIG),:,echo "note: gates.mk is not in this tree, so $(words $(CHECK_RIG_TARGETS)) engine gates are not in this sweep -- see HACKING.md")
	@MAUX_SWEEP=1 CHECKLOGDIR=$(CHECKLOGDIR) $(SWEEP_SH) scripts/sweep_par.sh $(J) $(SWEEP_TARGETS)

check-all-cross check-all-box:
	@$(if $(MAUX_RIG),:,echo "note: gates.mk is not in this tree, so $(words $(CHECK_RIG_TARGETS)) engine gates are not in this sweep -- see HACKING.md")
	@mkdir -p $(CHECKLOGDIR); fail=""; \
	for t in $(SWEEP_TARGETS); do \
	  printf '%-24s ' "$$t"; \
	  if MAUX_SWEEP=1 $(MAKE) -s $$t >$(CHECKLOGDIR)/$$t.log 2>&1; then \
	    echo PASS; \
	  else \
	    echo "FAIL  (see $(CHECKLOGDIR)/$$t.log)"; fail="$$fail $$t"; \
	  fi; \
	done; \
	if [ -n "$$fail" ]; then \
	  echo; echo "FAILED:$$fail"; exit 1; \
	else echo; echo "$(SWEEP_DONE)"; fi

check-all:
	@$(if $(MAUX_RIG),:,echo "note: gates.mk is not in this tree, so $(words $(CHECK_RIG_TARGETS)) engine gates are not in this sweep -- see HACKING.md")
	@mkdir -p $(CHECKLOGDIR); fail=""; \
	for t in $(CHECK_ALL_TARGETS); do \
	  printf '%-24s ' "$$t"; \
	  if MAUX_SWEEP=1 $(MAKE) -s $$t >$(CHECKLOGDIR)/$$t.log 2>&1; then \
	    echo PASS; \
	  else \
	    echo "FAIL  (see $(CHECKLOGDIR)/$$t.log)"; fail="$$fail $$t"; \
	  fi; \
	done; \
	if [ -n "$$fail" ]; then \
	  echo; echo "FAILED:$$fail"; exit 1; \
	else echo; echo "all gates green"; fi

# ---------------------------------------------------------------------------
# Per-volume ProDOS capacity REPORT (scripts/report_volumes.py). NOT a
# gate: it never fails a build, never contributes to any exit code, and
# is static analysis over already-built build/*.po files -- no emulator,
# safe to run alongside anything else. Derives its own volume set (see
# the script's own docstring for the three sources); an unbuilt volume
# is printed as "unmeasured", never a failure -- deliberately the
# OPPOSITE policy from check_kernel_images.py, where an unbuilt kernel
# image is a failure on purpose. Tracks the 800K/1600-block floppy
# figure as docs/ARCHITECTURE.md (commit 99ce0d0) settled it: a goal
# with a visible number ("you just spent the floppy"), not a ceiling --
# see the script's own docstring for the full ruling and its [likely]
# confidence grade.
report-volumes:
	python3 $(SCRIPTS)/report_volumes.py

# ---------------------------------------------------------------------------
# What each program pays liba, and how much of it nothing reaches
# (docs/REL-LIBA-SPIKE.md step 4).  INFORMATIONAL, like report-volumes --
# it never fails a build.  The spike's policy is "split a liba file when a
# consumer's byte budget demands it -- measure first"; this is the measure.
# ---------------------------------------------------------------------------
report-liba:
	python3 $(SCRIPTS)/report_liba.py

# ---------------------------------------------------------------------------
# Versioned release bundle. This intentionally requires an exact vVERSION tag
# and a clean index/worktree; release evidence must identify one immutable
# source state. ROMs, vendored third-party media, and provisioned dependencies
# are never copied into the distributable bundle.
# ---------------------------------------------------------------------------
VERSION ?=
DIST ?= dist

# Test tier only: it boots the packaged file in MAME and rebuilds liba
# with nas FRESH (FULL_LIBA_FRESH) to prove determinism.
ifeq ($(MAUX_TIER),build)
check-release-image:
	@echo "make release needs the test tier (MAME, and nas booted fresh); this tree was bootstrapped with TIER=build."; exit 2
else
check-release-image: $(MAMEROMS_DONE)
	python3 $(SCRIPTS)/check_release_image.py
endif

# VERSION is checked FIRST (it used to be checked after check-release-image,
# i.e. after minutes of work), then verify-remote (the network, before
# anything builds), then the determinism gate, then the packager.
release-version-check:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=X.Y.Z[-suffix]   or   make release-candidate VERSION=X.Y.Z"; exit 2; }

release: release-version-check verify-remote check-release-image
	python3 $(SCRIPTS)/build_release.py --version "$(VERSION)" \
		--image "$(FULLIMAGE)" --output-root "$(DIST)"

# A release CANDIDATE: no tag, a clean tree. Bundle, image and source archive
# are named maux-X.Y.Z-rc-<shortsha> and MANIFEST.json says "candidate":
# true, "tag": null, so it cannot be mistaken for the release. Every other
# step and check is the release path's; `make release` on an untagged HEAD
# still refuses (check-release-pack holds both). RC-1 uses this.
release-candidate: release-version-check verify-remote check-release-image
	python3 $(SCRIPTS)/build_release.py --version "$(VERSION)" --candidate \
		--image "$(FULLIMAGE)" --output-root "$(DIST)"

# The packager's own gate: scratch git repo, synthetic image, no emulator,
# no network. Rows in scripts/check_release_pack.py's docstring.
check-release-pack:
	python3 $(SCRIPTS)/check_release_pack.py

# ---------------------------------------------------------------------------
# `make public-tree PUBLIC_DIR=/path` -- materialise EXACTLY what ships.
#
# Without this, check-publish is advisory: it says what should ship and
# nothing builds it, so the public tree is assembled by hand and the gate's
# answer is a document rather than a mechanism. Here the gate IS the oracle
# -- `check_publish.py --list` prints the suppressed and withheld sets
# together, and this removes precisely those paths from a `git archive` of
# HEAD. Nothing is hand-listed twice.
#
# git archive, not a copy: it carries the tracked set at HEAD and no build
# products, no .git, no untracked scratch. That means vendor/ is absent (it
# is gitignored), so the result needs the documented bootstrap before it
# builds anything -- `make vendor-prodos vendor-merlin`, exactly as README
# tells a newcomer. The target prints that reminder rather than running it,
# because fetching into someone's output directory is their call.
#
# It refuses a non-empty PUBLIC_DIR: this writes a tree meant to be
# published, and silently merging it over whatever was already there is how
# a withheld file survives into a release.
PUBLIC_DIR ?= $(BUILD)/public-tree

public-tree:
	@test -n "$(PUBLIC_DIR)" || { echo "public-tree: PUBLIC_DIR is empty"; exit 2; }
	@if [ -e "$(PUBLIC_DIR)" ] && [ -n "$$(ls -A "$(PUBLIC_DIR)" 2>/dev/null)" ]; then \
	  echo "public-tree: $(PUBLIC_DIR) is not empty -- refusing to merge a"; \
	  echo "public tree over existing files. Remove it by name first."; exit 2; fi
	@$(MAKE) --no-print-directory check-publish >/dev/null \
	  || { echo "public-tree: check-publish is RED -- fix that first, it is"; \
	       echo "this target's only oracle. Run: make check-publish"; exit 1; }
	@mkdir -p "$(PUBLIC_DIR)"
	@git archive HEAD | tar -x -C "$(PUBLIC_DIR)"
	@python3 $(SCRIPTS)/check_publish.py --list > $(BUILD)/.notship
	@# This target runs rm over a list a script printed, so every line of
	@# that list must be a path git actually tracks. It was not always: the
	@# self-test banner used to go to stdout and arrived here as a 1042nd
	@# "path". rm -f shrugged at it and every count was wrong.
	@git ls-files > $(BUILD)/.tracked
	@bad=$$(grep -vxF -f $(BUILD)/.tracked $(BUILD)/.notship || true); \
	 if [ -n "$$bad" ]; then \
	   echo "public-tree: check-publish --list printed something that is not"; \
	   echo "a tracked path, and this target deletes what it prints:"; \
	   printf '  %s\n' $$bad; exit 1; fi
	@cd "$(PUBLIC_DIR)" && while IFS= read -r p; do rm -f "$$p"; done < $(CURDIR)/$(BUILD)/.notship
	@find "$(PUBLIC_DIR)" -type d -empty -delete
	@kept=$$(cd "$(PUBLIC_DIR)" && find . -type f | wc -l | tr -d ' '); \
	 gone=$$(wc -l < $(BUILD)/.notship | tr -d ' '); \
	 echo "public-tree: $(PUBLIC_DIR) holds $$kept file(s); $$gone removed"; \
	 test ! -e "$(PUBLIC_DIR)/gates.mk" \
	   || { echo "public-tree: gates.mk SURVIVED -- the rig set is wrong"; exit 1; }
	@# That last line is a backstop and should never be what fires: dropping
	@# gates.mk from the rig set turns check-publish RED first, because
	@# gates.mk's own header cites docs/PUBLISH-RIG-CUT.md, which does not
	@# ship. Shown both ways. The backstop costs one stat and covers the case
	@# where some future edit removes that citation too.
	@echo "public-tree: next, in that directory: make vendor-prodos vendor-merlin"
	@echo "public-tree:                          make image play-image check-all-host"

# ---------------------------------------------------------------------------
# `make check-all-host` -- every gate that runs with the TOOLCHAIN ALONE: no
# emulator, no ROMs, no verilogapple. This is the sweep someone who has just
# cloned the tree can actually run, and HACKING.md points them at it.
#
# It is a small fraction on purpose and the number is worth stating plainly:
# of the sweep's gates, these run here, the rest boot a machine. maux is an
# operating system -- most of what there is to assert about it is what the
# hardware does when the kernel runs, and that needs an emulator. What this
# list DOES cover is every static rule the tree enforces (the dialect, the
# column limit, ASCII, the kernel-image ratchets, the two hardware lints)
# plus the host side of all three differential gates, which is where a
# conformance bug usually shows first.
#
# TWO CAVEATS, both measured on the first run:
#   * three gates need no emulator and still cannot run alone --
#     check-kernel-images, check-prodos-version and check-volname read
#     build/ artifacts that OTHER gates produce, with the dependency
#     written in the script rather than in a prerequisite. They are named
#     in check_host_sweep.py's NOT_STANDALONE with their reasons, and are
#     out of this list.
#   * check-deps and check-publish take the LOCAL CHECKOUT as their
#     oracle (the dependency layout, and the git index). They pass on a
#     real clone and fail on an rsync'd tree, which is exactly why
#     CHECK_BOX_TARGETS filters them out -- so `sh scripts/box_gate.sh
#     check-all-host` shows those two red and that is not a defect. Run
#     this target on the checkout you are working in.
#
# DERIVED, NOT MAINTAINED BY HAND: scripts/check_host_sweep.py walks make's
# own rule database and fails if this list is not exactly the set with no
# transitive path to $(MCP_SUPERVISOR) and no mcp_drive.py in any recipe.
# A hand list would go stale the first time a gate here gained an image
# prerequisite, and the symptom would be a public clone dying with a build
# error where it expected a test result.
CHECK_HOST_TARGETS = \
                    check-deps check-deps-selftest check-sweep-par \
                    check-modules check-kbss check-ascii check-doctruth \
                    check-encoding-census check-publish \
                    check-host-sweep check-teeth-patterns check-lc \
                    check-man-image \
                    check-poison check-altzp check-memmap check-userland \
                    check-open-census check-lseg check-dialect \
                    check-stagebin check-strip check-e2e-host \
                    check-writefail-host check-dirfull-host \
                    check-nas-selfmake-image \
                    check-kledger check-e2e-fs-host check-release-pack

check-host-sweep:
	python3 $(SCRIPTS)/check_host_sweep.py

check-all-host:
	@mkdir -p $(CHECKLOGDIR); fail=""; \
	for t in $(CHECK_HOST_TARGETS); do \
	  printf '%-24s ' "$$t"; \
	  if MAUX_SWEEP=1 $(MAKE) -s $$t >$(CHECKLOGDIR)/$$t.log 2>&1; then \
	    echo PASS; \
	  else \
	    echo "FAIL  (see $(CHECKLOGDIR)/$$t.log)"; fail="$$fail $$t"; \
	  fi; \
	done; \
	if [ -n "$$fail" ]; then \
	  echo; echo "FAILED:$$fail"; exit 1; \
	else echo; echo "every gate that runs without a machine is green -- \
$(words $(CHECK_HOST_TARGETS)) of $(words $(CHECK_ALL_TARGETS)) in the \
sweep; the rest boot one"; fi

# ---------------------------------------------------------------------------
# TWO STATIC KERNEL LINTS. They encode hardware rules -- ALTZP steers
# three regions at once, and the language-card write-enable latch cannot
# be read back -- but neither one boots a machine: both read src/**/*.s
# and inc/*.equ and nothing else. They were in gates.mk for an afternoon
# on the strength of their names, which is exactly the mistake the rig
# cut warns about: read what a gate ASSERTS. A contributor editing kernel
# source needs these and can run them with no emulator and no ROMs.
# check-lc: the language-card ratchet -- only $C083/$C08B, tree-wide.
# Static, host-only, under a second, with a mutation self-test. The rule
# and the dead machine that produced it are in docs/LANGUAGE-CARD.md.
check-lc:
	python3 $(SCRIPTS)/check_lc.py

# The cross-flip cell-ordering ratchet. ALTZP steers zero page, the stack
# page AND the language card, so a cell written before `STA ALTZPAUX` and
# read after it returns the PROCESS's copy, not the kernel's -- and since
# a fresh bank is zeroed, the wrong value is a plausible zero rather than
# a crash. Five instances to date (docs/SYSCALL.md #5.1 and #7.7,
# sched.s, entry.s's K_RESULT, procspawn.s's PRC_STMP_BANK/BANK_ID); the
# last was latent for the life of the routine because nothing read the
# cell until `$$` was implemented. Sanctions are per-REGION, which is
# what gives the gate teeth: entry.s's bracket legitimately reads the
# stack page, and the historical bug was a zero-page read three lines
# away inside that same bracket. Static -- no emulator, no merlin32, so
# it needs no prior build and runs early with the other structural gates.
check-altzp:
	python3 $(SCRIPTS)/check_altzp.py

# ---------------------------------------------------------------------------
# THE ENGINE GATES live in gates.mk, which is not published, and neither is
# the ruling behind it (NOT PUBLISHED: docs/PUBLISH-RIG-CUT.md). Present: it sets MAUX_RIG and its gates join the sweep. Absent:
# the sweep is the gates this tree can actually run, and no recipe here
# points at a script that is not here.
#
# LAST IN THE FILE, and it has to be: a rule's prerequisites are expanded
# when the rule is read, so an include above the variable definitions gives
# every moved rule empty prerequisites -- measured, nine rules lost theirs
# silently, and `all` stopped being the default goal.
-include gates.mk
