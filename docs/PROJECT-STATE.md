# Project state and consolidation priorities

Status: LIVE, 2026-09-21 (0.1.0 candidate gates), first written at `8a0b964` after the
native `make` milestone. This file owns the current high-level assessment.
Chronological design documents remain evidence, but their old `NEXT`, `OPEN`,
and status prose does not override this page or a current gate result.

## Verdict

maux is a serious Unix implementation and native development environment for
the Apple IIe, built around an original architecture specific to that machine.
The architecture phase is over. The bank-per-process model has survived
implementation of preemption, process creation, `fork`, pipes, signals, job
control, ProDOS coexistence, terminal drivers, editors, and a native toolchain.

The strongest current claim is earned: maux can rebuild its assembly world
inside maux. The project is nevertheless not release-ready. Feature delivery
has outrun integration truth, onboarding, dependency pinning, and documentation
maintenance. Consolidation is the live front.

## What is proven

The 2026-09-19 `check-nas-selfmake` run reports:

```
MK2OUT empty -- the second make run had nothing to do
byte-identical: 85 of 85 staged utils
MAUXPLAY.SYSTEM (KERNEL, nas+ld -l k) 28921B byte-identical
kernel images byte-identical: 1 of 1
PASS
```

After the 2026-09-19 nas two-pass promotion, the staged graph contains 458 assembly
recipes and 118 links; these are composer totals, not executed-command counts.
The guest's own `make` selects the needed closure. The fresh native rebuild
takes 8.30 billion cycles; measured in the promotion profile.
The fresh original-baseline comparison is 16.50B -> 8.30B world cycles and
154.10M -> 50.75M warm cycles across five fixed real REL pieces. This removes further NAS
optimization from the immediate consolidation agenda.
The utility outputs and a kernel containing the complete kernel module closure
are compared byte-for-byte with independently cross-built references. The
empty dry rerun separately proves the build graph's freshness decision.

The broader evidence includes:

- 85 rebuilt utilities including `sh`, `ed`, `ex`, `vi`, `make`, and `ld`,
  driven by the native `nas` assembler;
- byte-level toolchain comparisons and REL/linker checks;
- fast and RTL emulator gates where fidelity matters;
- filesystem, process, terminal, write-failure, and directory-full scenarios;
- POSIX differential suites measured on 2026-09-17 at 518/518 utility cases,
  138/138 `sed`, 109/109 scored regex cases, 53/53 `ex`, and 64/66 `vi`;
- mutation/sabotage checks intended to prove that gates can become red.

These results establish much more than "boots" or "runs a demo."

**EXEC-SHEBANG (landed 2026-10-11).** Spawn inspects the file: BIN
(`$06`) and SYS (`$FF`) run as images, anything else is `ERR_NOEXEC`
(sh: `cannot execute`, `$?` 126; a chtyp'd file is re-checked on the
warm path). A TXT whose first line is `#!interp [arg]` runs through its
interpreter from sh's cold segment (SHEB_FIX, shsgblt.s; two levels
deep; `test -x` uses the same reader). sh now takes V7's `sh [-ex] SCRIPT
[ARGS]` with `$0` the script, and POSIX `sh -s [ARGS]` for a script on
stdin with arguments (architect's ruling: the V7 shape is the Unix one;
the two in-tree users say `-s`). Part 3: a `/dev` path never reaches the
MLI from ANY call (VR_DEVCALL at the chokepoint: CREATE on a known device
is a no-op, GET_FILE_INFO is a synthetic CHR/BLK stat, DESTROY/RENAME/
SET_FILE_INFO are `$4E`), closing the never-poll hole where `echo hi >
/dev/null` spun an unmounted Disk ][ (sh's `>` creates before it opens).
Cost: +37 B flat (MAUXPLAY 769 B to its cells, 1 B above the 768 B
ratchet), KSEG 141 -> 18 B, sh segment ~6,050/6,144. Gates: check-exec
(36 rows), check-devpath (40 rows, bit_pos 0 across each). KNOWN
LIMITATION, ruled 2026-10-11: scripts run only through sh -- find -exec,
xargs, env, nohup, time, timeout, make and the editors' bang spawn
binaries only and refuse a script cleanly; the trigger to move the
placement (liba SC_SPAWNX ~300 B x 11 programs, or the 4.2BSD kernel
placement ~300 B flat) is a user who needs `find -exec script`. Swept at
f04b68e: Mac 136/0, box 131/0. Commons: learning:01M4N1H2AYM1HKN71KJH3YBWGZ,
learning:01M4N1HGMZ7696FS7EE63T2ZRA.

KBRK (branch `kbrk`, awaiting architect review; docs/KBRK-NOTES.md): a BRK in
a USER process is SIGTRAP (signal 5, wait status `$85`, `$?` 133) -- the
process dies and the machine carries on; a BRK in the kernel (main's own
language card has its own `$FFFE`: timer.s MAIN_IRQ_SHIM parks it), in init
or in the idle process still halts. One zombie-marking routine now
(PRC_ZOMB/PRC_DIE). MAUXPLAY 29,909 -> 29,889 B (-20; every kernel image
-20), ratchet slack 19 -> 39 B. Gate: check-brk. Sweeps: see the notes.

KFIX3 (branch `kfix3`, awaiting architect review; docs/KFIX3-NOTES.md): sh
gets room first -- `ld @FILE` (the 31-word link-line cap is gone: sh,
more, vi, ex, nulib2 and diff link through `/tmp/LNK/<UTIL>`), a second
code segment at the language card's `$D000`, and the two biggest bss
tables placed inside the segments' now-dead low copy (SEG_INIT copies
only on a COLD spawn; a byte of text, SEGSTAMP, is the discriminator).
The binding budget was the `$BF00` WINDOW, not the four the brief named:
its margin was 561 B and went negative before this stream's own items
were in; it is +5,967 B. Then: `cmd > A 2> B` and every ordering of
left-to-right redirects (a piped stage's own redirects now apply too),
`N<F`/`N<&M`, V7's names for a foreground signal death (`Killed`,
`Terminated`, `Trace/BPT trap`), aliases inside `( )`, loops at `/`,
`/dev` and `/mnt` (the spool is in /tmp), and check-tenant's annex
compare by named regions with zero tolerance outside them. Found, not
fixed: `check-nas-selfmake` is red on the KERNEL on the base (91/91
utils byte-identical, kernel 0/1, `ld: undefined symbol PRC_BRK`) and
nothing in the sweep runs it. Sweeps: see the notes.

**KFIX4 (2026-10-17, docs/KFIX4-NOTES.md).** The native kernel rebuild was
dead since 2026-09-28 (fb4626b): the selfmake kernel objects sat in `/tmp/K`
while `ld -l k` finds its library as `<-L>/LIBK`, so it took nothing
(`undefined symbol PRC_BRK`). Objects now live in `/tmp/LIBK` with its
parent as a second `-L`; `check-nas-selfmake` is 91/91 staged units (88
UTILS -- 89 less `as`, which is pinned out -- plus `ld`, `proshimcr` and
`proshimpg`) plus the kernel byte-identical and is IN the sweep, with `check-nas-libpath` (host,
~0.1 s) in `check-nas-selfmake-image`. The `/dev` spin of the brief was
already fixed and gated (EXEC-SHEBANG Part 3); `check-devpath` now covers
the redirect twins and all four disk2 fields. `ls /mnt/<missing>` still
spins the drive (ProDOS's volume search; a kernel refusal needs a name
table: notes sec 2.2). check-librel/librelas/relink/selfmake were red by the
retired assembler windows; removal proposed here and carried out
2026-10-18 (RULINGS-1, below).

**KFIX5 (2026-10-18, docs/KFIX5-NOTES.md; branch `kfix5`, awaiting architect
review).** (1) The builtin-image spawn path (PRC_SPAWN's tag lookup,
PRC_LOAD_IMG, the K_BLTN tables and their dummy images) is a link-time twin,
spawnbl.s / spawnpl.s: only processtest, argvtest and envtest keep it
(measured: no gate in any of the 28 images reaches the hit arm); every plain
image shrinks 145 B (MAUXPLAY 29,924 -> 29,788), ratchet headroom 772 -> 908 B.
(2) `/mnt/<name>` is refused with `$45` before the MLI when no fast unit, the
boot volume or a mounted Disk ][ has that name: `ls /mnt/GONE` and its twins no
longer spin the drive, and `ls /mnt/FLOPPY` no longer lists an unmounted floppy
(VR_MNTCK in the LSEG; the cold segment has 18 B free, not 148). check-loop's
detach row now counts the ON_LINE call instead of watching the spin. (3) `cmd >>
/dev/null` works (sh skips the end-seek on a device). Review round: `bye`
of a tenant no longer hangs when a VBL tick is pending at the quiesce
(TMR_QUIESCE drains it; check-tenant row 9), a pre-existing tick-phase race.

**KFIX7 (2026-10-18, docs/KFIX7-NOTES.md; branch `kfix7`, awaiting architect
review).** (1) init never abandons the console: after five fast shell deaths,
or a failed spawn (it used to park at `$E5` / `$EE`), it prints `init: shell
failed, retrying` on the console, waits 12.8 s (a SYS_TICK poll: the kernel
has no timed sleep or yield; with no tick a fixed count of syscalls, because a
no-tick machine takes no keys) and respawns. KBRK R1 confirmed: a BRK left in
the retained shell bank respawns cold. check-init: phases flap / nosh / cold /
coop, teeth in the notes. MAUXPLAY 29,788 -> 29,914 B (ratchet headroom 782).
(2) Relative paths reach `/`, `/dev` and `/mnt`: readsyn.s RD_SYNCHK classifies
the canonical path (cwd + path, `.` / `..` resolved anywhere), so `cd /; echo
mnt/*`, `cd /mnt; echo ./*`, `cd /dev; echo ../*`, `echo /mnt/../*`, `ls mnt`
and `find dev` work; check-devfs case 7b replaces the four rows that pinned the
old behaviour. +112 B in each of the 12 programs that put readsyn.s.

**SLEEP-1 (2026-10-21, docs/SLEEP-1-NOTES.md; LANDED e7dd4c83, swept
99259cbb: box 156/0, Mac 161/0).** `sleep` sleeps: SYS_SLPUNTIL (call 26) blocks on a
V6-style global earliest deadline (K_SLP_DL, K_SLP_ARM), woken by the tick
hook (TTY_TICK -> SLP_TICK) on `now - deadline >= 0`; the target is
absolute (a blocked call is rerun whole on wake), the compare is signed
modular (right across the 32-bit wrap `/bin/sleep`'s old unsigned compare
got wrong), and the kernel refuses on a frozen-counter machine. A CPU-bound
foreground job (`cksum /bin/vi`) costs 100.4% with a background `sleep`;
with the polling `sleep` it was 194% for one and 381% for three. +161 B
flat in every kernel image (MAUXPLAY 30,267 -> 30,428). init's back-off is
unchanged (a bounded poll, by design). Gate: check-sleep (12 rows; teeth
6 of 6, teeth_sleep.py), plus a sleeper block in check-wake. Finding for a
separate sh stream: with ANY background job Running, sh's JOB_DRAIN costs
~13.8k cycles per command line (PRC_WAIT_CORE's 47-slot annex scan); notes
sec 10.

**ORPHAN-1 (2026-10-22, docs/ORPHAN-1-NOTES.md; branch `orphan-1`, ready to
sweep once the architect frees the box).** Orphans go to init at their parent's
death, V7 `sys1.c` exit() / 4.2BSD `kern_exit.c`: `PRC_ADOPT` gives
`PCB_PARENT := 1` (annex and `K_PAR_SHD`) to every process whose parent is a
ZOMBIE, after every death (exit, kill, kill-self, user BRK, and ONCE after a ^C
sweep); a STOPPED adoptee gets SIGHUP then SIGCONT through its own disposition
(default: dies `$81`, and its children are adopted in turn); init is woken for a
zombie adoptee. No MLI in tick/BRK context (the fd closes stay in `PRC_REAP_ONE`,
where init's wait reaps). A respawned console shell in a reused pid no longer
adopts the old shell's `&` job. `PRC_REAP_ORPH` is deleted: it cost ~12.9k
cycles a call and ran twice per foreground command, so a command is ~24.9k
cycles cheaper net. MAUXPLAY +87 B flat (30,520 -> 30,607). Gate: check-wait
grew nine rows (scripts/wait_orphan.py, teeth scripts/teeth_orphan.py);
check-jobctl-a's orphan cases were rewritten; MAUXSHLANG's harness pid 1
now discards adoptees.

**RULINGS-1 (2026-10-18, docs/RULINGS-1-NOTES.md).** Two operator rulings.
(1) The four Merlin-window gates are retired for good: `check-selfmake`,
`check-librelas`, `check-librel` and `check-relink` -- their Makefile targets,
`build_librelas_image.py` and the three dedicated drivers are deleted
(`check_librel.py` stays as the library `build_nas_librel_image.py` and
`KERNEL_LISTINGS` import; `relink.py` stays as the REL-format reference model).
None was in `CHECK_ALL_TARGETS`, so the sweep count does not move.
`check-nas-selfmake` (88 UTILS, `ld`, `proshimcr`, `proshimpg` and the kernel)
is the replacement. (2) `PRC_KILL` no longer refuses the console shell: init
respawns it. 21 B freed in the flat kernel (MAUXPLAY 29,921 -> 29,900).
`kill -9 $$` and `kill $$` give a fresh cooked shell; an `&` job survives and is
adopted by slot identity; a flap backs off and never parks. One defect found on
the way and fixed: the `PRC_TMD_RST` backstop resets only a foreground-set
victim and the shell is never in its own, so a raw console outlived its shell --
an interactive `sh` now stamps cooked + echo at start (the getty rule; 0 flat
bytes). `check-jobctl-a`'s `shell_protected` is replaced by four cases.

**Loop device S2-S4 (landed 2026-10-11).** S2a: a failed WRITE through
the loop discards ProDOS 2.4's volume-bitmap buffer at the failure
(bmaDev `$FE9A` = `$B0` -> bmaStat `$FE99` := 0) and again at detach;
attach verifies 2.4's UpdateBitMap bytes at `$EB42` and refuses any
other ProDOS ("needs ProDOS 2.4 (bitmap cells)"); `umount` reports `N
blocks were not written` and exits 1 (the unit is detached; the status
says the data was not -- architect: lost writes are never a silent
success). `mount -r` and write-protected images mount read-only (the S1
refusal is gone). S2: `.2mg` (ProDOS order, dataOffset 1-64) mounts
read-only via a 64-byte carried-tail path, 18,022 cycles a request
against 4,067 for a .po. S3: `mount FILE` densifies a sparse image
first (every all-zero block rewritten so ProDOS allocates it; `-r` reads
holes as zeros and writes nothing). S4: `bye` detaches the loop before
PRC_RAMRECONN (the 13 `$FF00` bytes restored, bitmap discarded, VCB
freed) and re-attaches the same image after "Welcome back." if it still
passes attach, else says why. Cost: 0 flat bytes; LSEG 1,039 -> 1,719 B
(329 B of its region left); KSEG net +3 B. check-loop is 194 rows (S1:
93). Open finding, not loop code: a tenant `bye` itself moves the Disk ][
bit_pos once on main (629,917) -- ProDOS in the tenant window; for whoever
owns `bye`. Swept at d36133a: Mac 134/0, box 129/0; the two streams were
integrated and swept together before landing: main da5758b, Mac 136/0, box 131/0.

**Loop device S1 (landed 2026-10-11, main c171d03).** `mount IMAGE.po`
attaches a dense ProDOS tree-file image as unit `$B0` (slot 3 drive 2,
the dead /RAM slot); its volume appears under `/mnt`, `/dev/s3d2` is its
block device, `umount` detaches with the ON_LINE that frees the VCB
(docs/LOOP.md design A; docs/LOOP-S1.md and its ruling; numbers in
docs/LOOP-S1-NOTES.md). The driver, its 1.5 KB index cache, attach and
detach live in a play-only LOW SEGMENT at `$1300-$1FFF`
(src/kernel/loopseg.s, file `LSEG`, loaded by KSEG_LOAD beside KSEG);
`$FF00` holds a 13-byte host-call trampoline; the image file stays OPEN
on one kernel pool buffer while mounted. Cost: a hit adds 325 cycles to
the host's 3,715; flat kernel +61 B (32 B above the floor -- the next
UNIVERSAL kernel byte needs a stub-image KSPACE stream); KSEG 130 B
free. Refused at mount: sparse images (S3 densifies), .2mg (S2),
seedling/sapling, write-protected images, a second mount, and `bye`
while attached (S4). Measured: ProDOS 2.4 enters block drivers with
interrupts MASKED, so the driver has no sei/cli; a failed WRITE leaves
ProDOS's bitmap buffer dirty across a detach (accepted gap, trigger: the
first stream that writes through a host that can fail). Gates:
check-loop (93 rows, 30 red on the old image), check-lseg (layout
ratchet with self-test), check-devfs/check-bye rows. Swept at 6c2f23c:
Mac 134/0, box 129/0. Open: `echo hi > /dev/null` spins an unmounted
Disk ][ (never-poll ruling; not loop code).

**Loop device S2a-S4 (branch loop-s2, 2026-10-11; unmerged until the
architect merges; docs/LOOP-S2.md, numbers in docs/LOOP-S2-NOTES.md).**
`mount -r IMAGE` mounts read-only and a write-protected image mounts
read-only instead of being refused: ProDOS 2.4's dirty volume-bitmap
buffer (bmaStat `$FE99`, owner bmaDev `$FE9A`, found by M1 on 2.4) is
discarded by the driver the moment it fails a WRITE and again at
detach, and `umount` reports "N blocks were not written". `.2mg`
(ProDOS order, dataOffset 1-64) mounts read-only through a two-read
carry in the caller's own buffer (4.4x a .po READ). `mount` densifies a
sparse image first ("densified N blocks"; -r reads holes as zeros and
writes nothing). `bye` no longer refuses with a loop attached: it
detaches before /RAM is handed back, the `bye` tool attaches it again
afterwards or says why not. ZERO flat or universal kernel bytes (KSEG
-3 B; the low segment grew to 1,719 B of 2,048). check-loop 194 rows.
Open: a tenant `bye` moves the Disk II once on main too (ProDOS's own).

**Virtual root (landed 2026-10-10, main bcacf51).** `/` is a table the
kernel owns (src/kernel/vroot.s, docs/VROOT.md): `bin usr etc tmp` map
onto the boot volume's directories, `dev` is synthetic, `mnt` lists
MOUNTED volumes (fast units automount; a Disk ][ volume needs `mount
/dev/sNdM`, `umount` releases it; the same verb will attach /dev/loop
images). The boot volume is named MAUX and is visible as `/mnt/MAUX`;
the ProDOS plumbing files live only there. Translation happens once at
the syscall boundary (PRC_ABSPATH marks a typed-absolute or
synthetic-composed path VR_PEND; VR_XLATE_P rewrites it in place); cwd
slots stay physical; PRC_GETPFX reverse-maps. The kernel's own `..`
machinery is gone: sh pops `..` in userland on the virtual text. Cost:
MAUXPLAY flat headroom 1,079 -> 349 B; MAUXEXPR, the tightest stub
image, has 7 B below its ceiling, so the next UNIVERSAL kernel byte
needs a KSPACE-style stream for the stubs. Gates: check-mount (33 rows,
red on the old image), check-volname (no slash-BASIC path literal in live
files, every boot image's volume is MAUX). Swept at 3f6847a: Mac 132/0,
box 127/0. Open for the operator (docs/VROOT-NOTES.md "Rulings"): the
typed path is capped at 64 VIRTUAL characters; a map target has one
name (`cd /mnt/MAUX/BIN` prints `/bin/`); `mount` lists in DEVLST order.

**Which ProDOS (ruling 2026-10-08).** Every image boots the vendored ProDOS
2.4 kernel, gated by `check-prodos-version` since the same day. The
2026-08-17 "target 2.5" ruling is withdrawn: 2.5's Extended date format
makes the volume no longer ProDOS, and its root-directory growth and
alpha status are not wanted. The one 2.5 property maux keeps is GS/OS
case-preserving names, which the kernel writes itself
(docs/PRODOS-CASE.md, open). Dates stay the legacy 7-bit layout with the
year pivoted at 78 (window 1978-2077; docs/PRODOS-VERSION.md).

## What self-hosting means here

The completed milestone is a **native self-rebuild**:

1. maux boots with `make`, `nas`, `ld`, source forms, and libraries staged;
2. guest `make` assembles and links the system;
3. the rebuilt files are verified independently;
4. a second dry run finds the graph clean.

It is not yet a **closed bootstrap from canonical source media**. Host Python
still performs source transformation and piece generation, cooks the staged
PLASMA `nas` binary, creates ProDOS images, drives the emulator, and harvests
the results. `nas.pla` itself is not rebuilt as part of the same world graph,
and the boot block/image-construction path is outside it. This boundary is not
a defect in the completed milestone, but it must remain explicit.

Closed bootstrap is a separate possible milestone: stage a minimal trusted
seed, compile PLASMA and `nas` on the target, rebuild the assembly world, and
construct bootable media without project-specific host transformations.
Closed bootstrap is deferred during consolidation. The current host-prepared
seed boundary is explicit, not a missing prerequisite for the native rebuild.

## Accepted criticisms and risks

### 1. There was no truthful canonical green

Immediately before this document, `CHECK_ALL_TARGETS` contained the superseded
Merlin/Sweet16 `check-selfmake`, which is known not to build: the staged regex
form exceeds that assembler's source window and stale-listing dependencies can
fail first. The successful `check-nas-selfmake` was absent because executing it
then cost 21.35 billion cycles.

The first consolidation change replaces the broken legacy gate in `check-all`
with `check-nas-selfmake-image`. The affordable target constructs the entire
native self-host image and asserts the graph against `make`'s real capacity
constants. The expensive execution/byte-comparison remains an explicit
milestone or scheduled gate. The legacy target was left callable for a month
and RETIRED 2026-10-18 (RULINGS-1): the Makefile target and its image builder
and driver are deleted.

This repaired the definition, not the evidence retroactively. The saved
2026-09-18 full sweep at `828309c` failed `check-posixutil`, `check-e2e`,
`check-librel`, `check-librelas`, and `check-relink`.

**Those five are now triaged, 2026-09-19/20, and none was a toolchain or
kernel regression** -- the sweep (`make check-all` at `828309c`, 99 of 104) was archived with its failure logs:

- three (`check-librel`, `check-librelas`, `check-relink`) were one undone
  ruling about the SUPERSEDED assembler's source window, not defects. They
  were retired from `check-all` by the 2026-09-20 ruling and deleted
  2026-10-18 (RULINGS-1); what that gives up is stated in
  [verification](VERIFICATION.md).
- `check-e2e`'s three cases were a stale divergence-ledger entry, not a `wc`
  defect: `wc` grew its totals line on 2026-09-17 and the entry saying
  "delete this when wc grows one" outlived it by two days. Fixed; two of the
  three cases now check the totals line against the host for the first time.
- `check-posixutil`'s single non-gap divergence was a real `ls -R` defect
  (a directory header the host does not print). Fixed.

**The candidate sweep has now been RUN, 2026-09-20: 102 of 104.** First sweep
of the new list (`check-ascii` and `check-man-image` in, the three legacy gates
out), 398 seconds at J=4, archived with its two reds.
Neither red was what its message claimed:

- `check-idle` failed on its own SAMPLE BUDGET while the share it measures
  (2.6%, limit 5%) passed -- a fixed 12,000,000-cycle settle against an
  assembly the promoted nas now finishes in 12,780,000. The settle is measured
  now, not assumed; it passes with all 400 samples and its teeth were re-proved
  by sabotage after the change. CLOSED.
- `check-jobctl-a` was a real defect and its message was wrong: not a leaked
  PCB slot but `KRN_BRK_TRAP` -- the kernel took a BRK and parked with
  interrupts masked, so the whole machine was dead. **CLOSED 2026-09-20 in
  `299d0ae`.** The BRK's return address named `sh`'s own second code segment,
  which had been half-installed: `SEG_INIT` held the language card's
  write-enable across a 4 KB copy and another process's LC bracket closed with
  a write-protect in between, so the tail of the copy was dropped by the
  hardware without a fault. Write-enable is now the machine-wide steady state,
  because it is one latch for the whole machine and no scheduler can save and
  restore what it cannot read. Mechanism, measurement and the two new gates:
  [LANGUAGE-CARD.md](LANGUAGE-CARD.md).

**A complete canonical green now exists: 106 of 106 at `299d0ae`**, archived
in `evidence/` (106, not 104, because `check-lc` and `check-lc-prodos` are new). The native
world pass is still owed at that revision, and the box variants still cannot
run -- the Linux box has no `mandoc`, which `check-man-image` needs.

The paragraph that follows described the state before that run:
named defect rather than an unknown. Closing it, then a clean-host repeat, is
what stands between this revision and a release candidate.

### 2. Reproducibility exists; the current candidate still needs qualification

Before the first consolidation slice, the Makefile and many scripts assumed
sibling repositories under `~/src` or `~/src`. The emulator gates
additionally depend on a verilogapple integration branch combining tools not
all present on its main branch. PLASMA and a2til were consumed as live sibling
trees rather than pinned artifacts.

Consequences at the original assessment (before the changes below):

- a clean checkout is not sufficient to reproduce the project;
- external revisions can drift without a maux commit changing;
- a successful local sweep is not yet a third party's reproducibility proof;
- there is no release manifest tying source, tools, ROM expectations, and
  output image hashes together.

The dependency/bootstrap changes below address that original diagnosis.
They are implemented work, not a fresh backlog. Release packaging also
exists; [RELEASE.md](RELEASE.md) describes it. The remaining qualification
must bind the current candidate, its dependencies, tests and output together.

**First slice landed with this assessment:** `dependencies.lock.json` and
`check-deps` pin the three source trees and host tools, verify the supervisor
and worker binaries rather than merely finding them, make all a2til imports and
the PLASMA/verilogapple paths overrideable, and remove the primary `/Users/mdj`
defaults. `docs/DEPENDENCIES.md` records the remaining box and ROM limits.

**Second slice landed after this assessment:** `make bootstrap-deps` now clones
the locked source revisions into a new project-local tree, validates and stages
the exact operator ROM set, builds `xplasm`, both emulator tiers, and the SDL2
frontend, and runs `check-deps` before publishing its Make configuration. It
refuses to modify an existing destination. A temporary clean-clone reproduction
on the known macOS host is part of that change's verification.

**Independent host proof completed 2026-09-18:** a clean checkout at `a04c49f`
bootstrapped on Debian 12 x86_64 with the locked versions. Dependency audits
passed before and after two immediate MCP rebuilds; public vendor inputs,
`play-image`, the SDL launch path, and fast plus RTL boot gates passed while the
source checkout stayed clean. `docs/HOST-PROVISIONING.md` records the exact
trusted host seed and source-archive hashes. The host compiler/package layer is
declared, not hermetically provisioned.

### 3. Documentation records history better than current truth

The repository has unusually valuable design archaeology, but several files
continued to present old state as current state. At this milestone:

- HACKING.md still said no kernel existed;
- `COMPLETISH.md` said there was no full-screen editor or readline/history;
- `PLAN.md` called self-hosting partial with two over-budget units;
- task sections often retained old `NEXT` actions above later amendments.

Historical reasoning should not be deleted. It should be marked historical and
linked from a short live status. New status changes belong here, in README, and
in the acceptance targets; design diaries should state the commit/date of the
state they describe.

### 4. Verification is broad but uneven

The strongest gates have independent oracles and have caught real defects.
Other areas share author assumptions between implementation and test or rely on
generic repeat/poison checks. The current poison audit itself distinguishes 14
programs with strong independent-oracle coverage from 62 covered by the weaker
generic auditor, with nine programs carrying explicit poison debt.

The answer is not more raw test count. New work should prioritise boundary
cases with independent oracles, real-hardware observations, and failures whose
expected result was not copied from the implementation.

### 5. The development loop is historically authentic but slow

The native world build now costs 8.30 billion CPU cycles. The following
individual timings are historical, before the nas optimization. Small utilities
are practical (`make echo` about 29 seconds and `make grep` about 85 seconds at
1.023 MHz), while `vi` and `sh` take roughly 19-20 minutes. An untargeted
no-op walk was measured in minutes because ProDOS directory lookup is linear.

This does not weaken the correctness milestone, but it limits native iteration.
Directory partitioning and graph locality are more promising than micro-
optimising the assembler: measurement attributes most no-op time to repeated
directory scans.

### 6. Complexity and bus factor are now architectural concerns

The project has hundreds of source and harness files, a large generated-image
surface, many fixed-capacity arenas, and a single primary contributor. Assembly
files often preserve entire defect narratives inline; useful context competes
with the executable contract. Mechanical source splitting makes the native
build fit but increases cross-file coupling and generated-graph complexity.

The static audits and byte gates control much of this risk, but they do not make
the system easy to change. Consolidation should favour fewer canonical paths,
smaller live documents, machine-readable manifests, and deletion or archival of
superseded mechanisms.

### 7. This is not a protected or fully POSIX system

The absence of memory protection is an explicit architectural axiom. maux is
single-user, has no C compiler or network stack, and inherits ProDOS storage and
timestamp semantics. Known shell and utility gaps remain recorded in the POSIX
suite; some hostile interactions can still hang the console or shell. Emulator
coverage is much broader than the physical-hardware matrix.

These are valid scope choices. They become defects only when omitted from the
project's public description or when a Unix-compatible spelling silently does
something materially different.

## Current contribution order

Updated after the 2026-09-20 coherence pass, which closed item 1:

1. ~~**Close integration.**~~ DONE 2026-09-20. The promoted NAS, the manual
   corpus, the permanent gates and the retained experiments are committed and
   classified; three `check-all` gates had been calling files that existed
   only in a working tree, so no clean checkout could have passed the sweep.
   [NAS.md](NAS.md) now registers which NAS scripts are gates, which are
   opt-in oracles, which are live reproducers and which are experiment
   material.
2. ~~**Close the canonical sweep.**~~ DONE 2026-09-20: **106 of 106** at
   `299d0ae`. The orphan-subshell BRK is closed (a language-card write-enable
   held across a preemptible copy -- [LANGUAGE-CARD.md](LANGUAGE-CARD.md)).
   `check-all-cross` is no longer a weaker list than `check-all`; the box
   variants still are, and `check-all-cross-par` needed `$(SWEEP_SH)` before it
   would run on the Mac at all.

   ~~Still owed at that revision: the native world pass, and the box sweep,
   which cannot run until the Linux box gets `mandoc`.~~ **BOTH CLOSED
   2026-09-21 at `52a54cf`**, together with the two release-tooling gates,
   which is the first time all four have been green at one commit:

   | gate | result |
   | --- | --- |
   | `make check-all-cross-par J=4` (Mac) | 110 of 110 |
   | `sh scripts/box_gate.sh` (Linux box) | 105 of 105 |
   | `make check-nas-selfmake` | 85 of 85 utils + 1 of 1 kernel byte-identical, empty dry rerun |
   | `make check-release-image` | 4,194,304 B, two builds byte-identical |

   Summaries retained in
   [evidence/candidate-52a54cf-2026-09-21](../evidence/candidate-52a54cf-2026-09-21/README.md).
   The kernel the native pass rebuilds is 29,509 B -- the same-day
   `/etc/RC` work included -- so the native world is not lagging the
   tree. One caution that cost a red: the box runs from an `rsync` and
   `build/` is deliberately not synced, so a stale box artifact can outlive
   the change that produced it (its cached man renders predated its own
   `mandoc`, and that gate re-renders and compares bytes).
3. **Repeat candidate reproduction.** Use the existing lock/bootstrap and
   second-host procedure for this revision. The earlier clean-host proof is
   valuable, but does not certify subsequent changes. **This is now the only
   automated milestone criterion outstanding** -- and note that the box sweep
   above does NOT discharge it: a second HOST running an `rsync` of the working
   tree is not a clean CHECKOUT from pinned dependencies. It has to be the last
   thing done, because a fix afterwards starts a new candidate.
4. **Qualify and package.** Use the existing release tooling; bind source,
   image, dependency identities and gate evidence to one revision. Keep the
   support matrix and known limitations beside the artifact.
5. **Broaden physical verification separately.** Record exact configurations
   and long-session results before changing any unverified support row. The
   original UltraTerm remains unsupported pending its named defect's closure.

   **Direction (operator, 2026-09-22): real hardware soon, and give `tip`
   a remote worth dialling.** A WiFi dongle on the end of a Super Serial
   Card -- the class of device that presents as a Hayes modem over RS-232
   and opens a telnet session on command -- would let a real //e reach
   another box on the network. `tip(1)` and the SSC both shipped in
   September, but `check-tip` only ever talks to the host shell through
   the emulator, so the utility has never had a remote that was not a
   local loopback.

   Worth recording because several deferred items hang off it rather than
   off each other:

   - It is the first thing that would make maux's serial support
     falsifiable on real silicon, where today it is verified only against
     verilogapple's model of an SSC.
   - It gives `tip` a purpose beyond the current one, which is the stated
     precondition for a file-transfer path off the machine.
   - A transfer path is in turn what would make WRITING a Binary II
     wrapper worth doing (`docs/NUFX.md`): ShrinkIt's own documentation
     says a `.BXY` exists for uploading to services whose comms software
     cannot attach the header itself. maux reads them today and has no
     reason to write one until something carries a file over a link that
     loses its ProDOS type.
   - Real hardware is also the only way to close the open Zip Chip
     question HACKING.md names: whether an 18-cycle-per-byte aux-to-main
     copy scales with the module clock.

   Nothing here is scheduled. It is written down so the ORDER is not
   rediscovered: dongle, then a real remote, then transfer, then `.BXY`.

Maintain status/documentation truth throughout; [docs/README.md](README.md)
maps live guides and historical evidence. Further NAS tuning, AOT, closed
bootstrap and new feature surface are deferred during consolidation. Host
preparation remains part of the declared trusted seed for this milestone.

## Definition of a releasable milestone

A release candidate requires all of the following:

- a clean canonical sweep at the tagged commit;
- a clean `check-nas-selfmake` at that same commit;
- a clean-checkout build on a second host from pinned dependencies;
- a bootable image, source archive, hashes, and dependency manifest;
- a short hardware/emulator support matrix;
- named known defects and conformance gaps;
- current README and agent instructions.

Until those hold, maux is an exceptionally well-verified development system,
but not yet a reproducible release.

**Status of those seven at `52a54cf`, 2026-09-21** -- the 0.1.0 candidate:

| criterion | state |
| --- | --- |
| clean canonical sweep at the tagged commit | **MET** -- 111/111 Mac, 106/106 box at `703ad36`, 2026-09-21 |
| clean `check-nas-selfmake` at that commit | **MET** -- 85+1 byte-identical |
| clean-checkout build on a second host from pinned dependencies | **HALF MET, 2026-10-30** -- `make public-tree PUBLIC_DIR=...` materialises the shipping set from `git archive HEAD` and that tree built and swept clean (`make vendor-prodos vendor-merlin`, then `make image play-image check-all-host`: 25/27, the two reds by design). That is the CLEAN-CHECKOUT half and it is now a target rather than a one-off. The SECOND-HOST half is still owed, and the box's `rsync` still does not count |
| bootable image, source archive, hashes, dependency manifest | tooling ready (`make release VERSION=0.1.0`); not yet run, and it refuses a dirty tree or a missing tag |
| short hardware/emulator support matrix | [SUPPORT.md](SUPPORT.md) exists; needs a truth pass at this revision, and must not imply physical-hardware qualification |
| named known defects and conformance gaps | [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) + the POSIX scoreboard, now **565/565 conforming with 23 gaps** (from 40) and each gap priced -- 8 permanent, 1 cheap, 3 harness-blocked, 11 in three named purchases; one OPEN measured defect (fast type-ahead leaves two prompts on one line) |
| current README and agent instructions | needs the same truth pass |

So 0.1.0 is not blocked on code. It is blocked on one reproduction and a
documentation pass, plus whatever product decisions get taken on `shutdown`
and `bye`.

**The publish rig cut landed 2026-10-30.** The ruling and the per-gate
tables are in-house only (NOT PUBLISHED: docs/PUBLISH-RIG-CUT.md) --
that is the one document which must not travel with what it
withholds. The engine
gates -- the 62 that boot a machine and assert what the HARDWARE does --
live in `gates.mk`, which `-include`s at the end of the Makefile and is
not published; `CHECK_RIG_TARGETS` names them as data so a tree without
that file drops them from the sweep and says how many are missing.
`check-publish` gained a third category (ships / suppressed-as-internal
/ withheld-as-rig, 112 files pinned by name), `make public-tree` builds
the shipping tree with that gate as its only oracle, and
`make check-all-host` is the 27 gates that need no emulator, derived
from make's own rule database and asserted by `check-host-sweep`.

Three rules came out of it that are easy to collapse by accident: a
shipping file may **name** a withheld path, may not **import** one, and
may not **assert that one exists**. The second and third were each found
by a defect, not by review -- the third only by building the published
tree and running it, which is now the documented way to check a publish
gate at all. Box sweep 174 PASS 0 FAIL at `1540418b`, plus the four
Mac-oracle gates green (842/842 POSIX cases).

**`bye` slice 1 landed 2026-09-26, merge `658a7d3`, box sweep 111 PASS
0 FAIL.** maux suspends itself to a RamWorks bank, QUITs to ProDOS,
regains control through ProDOS's own dispatcher and resumes the caller;
`check-bye`, three witnesses, three sabotages proven. Slice 2 (a real
`.SYSTEM` launch plus an exit-status convention) is unstarted.

Two things landed with it that are not about `bye`. `ld` gained a `-L`
that resolves explicit module operands rather than only `-l` libraries,
which is what let a kernel harness's generated link line fit inside
`sh`'s `LINEMAX`. And `PRC_RAMDIS` now OBEYS the /RAM aux-ownership
protocol it had only been reading -- maux refuses to boot when another
program owns aux, or when the machine has none -- which immediately
exposed an older defect: its DEVLST scan matched ProDOS 2.4's `$BF`
type nibble and ProDOS 2.5 writes `$B0` for the same slot 3 drive 2.

**Two `bye` defects closed 2026-09-26, merge `ee10708`, sweep 112/0.**
The cached save-bank number is now verified against a stamp before
every use (sabotage 3, previously unautomatable, is a fourth
`check-bye` witness). And the page-1 save had been landing inside the
main-image window over the tail of the io_buffer lending store -- slot
15's saved path and mark -- and `PRC_CANON`; measured at 62 of 68 bytes
corrupted per round trip, moved to the save bank's own aux
`$0180-$01FF`, and gated by the new `check-oftbye`. Fixing it exposed a
third: the restore cannot flip ALTZP from LC-resident code, because
ALTZP selects which language card is mapped, so it lives in the `$1000`
trampoline. `MAUXPLAY.SYSTEM` headroom is now 284 B. One lending edge
case recorded, not chased: with all eight io_buffers held by unrelated
files a spawn fails with "command not found".

**Annex save + /RAM for the tenant, 2026-09-26, merge `e3684fe`,
sweep 113/0.** `bye` now saves aux bank 0 to a second stamped bank,
reinstalls /RAM (inverse of `PRC_RAMDIS`, gated on `K_HAD_RAM`), hands
the tenant a formatted volume, and on return disconnects /RAM again
before the tick is re-armed, then restores the annex. One ProDOS fact
came out of it: formatting /RAM through its driver vector, as the TRM
documents, hangs a caller in main memory because the driver returns
with RAMRD/RAMWRT on aux -- `bye` writes the empty volume itself from
LC-resident code. `check-rambye` guards the annex against the bank's
own snapshot, and `check-bye` now exercises the machine as a person
after the return: `echo`, `ls`, a fresh background `sleep` finishing
on its own, a parked file reading back. `MAUXPLAY.SYSTEM` headroom is
77 B.

**The tenant launch landed 2026-09-27, merge `43e250a`, sweep 114/0.**
`bye PATH.SYSTEM` runs a real `.SYSTEM` on the handed-over machine --
it writes files through real ProDOS, prints through the ROM, QUITs --
and maux comes back with a legible console. Three facts came out of it
that bind any tenant launch: firmware scratch in the screen holes must
not be destroyed; the tenant needs the ROM readable, selected from
main memory because the select unmaps LC code; and the console puts
its own glass back. `MAUXPLAY.SYSTEM` now has **zero bytes** below the
harness cells, and block devices (`DEV-BLOCK.md`, built and parked)
need +1096 B in every image. **The kernel cold segment in LC bank 2 is
the next requirement, not an option.**

**The kernel cold segment landed and was boot-tested 2026-09-27,
docs/KSEG.md.** `PRC_BYE`/`PRC_RAMRECONN`/`PRC_RAMREDISC` and the
`/dev/sNdM` block-device dispatch (`DEV-BLOCK.md`) now live in LC bank
2 at `$D400-$DFFF`, reloaded from `/mnt/MAUX/KSEG` on every boot and
after every `bye` tenant return via a generalized `KSEG_LOAD`
(`PBY_LOAD_RES` is now a thin wrapper over it). MAUXPLAY.SYSTEM's
headroom crisis (565-589 B over) closed at **294 B of headroom**
below the harness cells, above the pinned `PT_HOLD_HEADROOM_FLOOR=256`
floor. Three real boot-halting bugs were found and fixed only by
actually booting (an unpadded segment file; ProDOS's own
`MLI_ERR_EOF` status mishandled as a generic error; a shared close-
plus-free tail that clobbered carry after the fact) -- the prior
round's `[likely]` io_buffer-corruption hypothesis is REFUTED: both
halts were loader-logic marks (`K_HALT_MARK` `$7C` then `$4C`) inside
`KSEG_LOAD` itself, never a memory collision. `make check-kseg` (new
gate, all four docs/KSEG.md cases) and `make check-play`/`check-bye`/
`check-tenant`/`check-rambye`/`check-oftbye`/`check-lcbank`/`check-dd`
all PASS on the resulting build.

`]KSEG_WANT` scoping is MAUXPLAY-only, accepted for this landing
(docs/DEV-BLOCK.md names the trigger for widening it). Two gaps found
this round, neither fixed: **`check-nas-librel` FAILS** -- nas has no
`do`/`fin` conditional-assembly directive at all (confirmed against
its own directive table), and five kernel files gate KSEG-related code
behind `do ]KSEG_WANT`, blocking the native nas+ld path from building
them; and **`check-devblk` FAILS post-merge** -- the /dev branch was
"green in isolation" before landing on the segment and has not
actually been run since, and now hangs before a shell prompt with the
same 40-column force `check-play` uses successfully on the plain play
image (docs/DEV-BLOCK.md has what was ruled out).

**The floppy round trip landed 2026-09-28, docs/FLOPPY-E2E.md, this
task's base `c56ee54`.** `check-floppy` boots on verilogapple with a
REAL 280-block 5.25" floppy on slot 6 (nibblized by verilogapple
spec-12), `dd`s it through ProDOS's own built-in Disk ][ driver via
`/dev/s6d1` -- BOTH with an explicit `count=280` and with none at
all (the operator's own sentence) -- archives it with `nulib2 -a`
into a `.SDK`, and proves the bytes byte-identical three independent
ways on the host (a2til's `disk_record.read()`, real `nulib2 -x`,
real `nulib2 -i`) -- the definition of done for the kernel cold
segment, `/dev` block devices, and `.SDK` writing landing in the same
round together. It found and fixed a REAL kernel bug no prior gate
could have exercised: `/dev/sNdM` had no end-of-media check at all,
so a no-count= `dd` walked off a floppy's formatted end into a track
the WOZ nibblizer leaves undefined -- genuinely non-deterministic,
sometimes a clean error, sometimes a crash. Fixed by caching each
open device's own `total_blocks` at open time and clamping every
read/write against it (`kdevblk.s`'s `PBLK_EOF_CK`/`PDEV_BLK_SIZE`,
placed in the kernel cold segment itself so the fix costs the
flat image's own 256 B headroom floor nothing -- measured at 261 B
after). An EARLIER diagnosis attributed the same crash to the
built-in Disk ][ driver toggling the language-card ROM/RAM switch
under maux's interrupt-enabled MLI bracket; that mechanism was
MEASURED FALSE on coordinator review -- a controlled A/B (interrupts
restored, EOF fix landed, fresh fixture volume) completed cleanly
every time -- and the commons deposit was corrected in place rather
than left standing. maux's interrupt-masking change to
`procdev.s`'s two block-driver MLI wrappers was KEPT anyway, on the
independent, better-grounded basis that real ProDOS 8 documents an
interrupt-masked caller for disk access; every other MLI wrapper,
and every existing SmartPort-only gate, is unchanged. Measured:
74,400,000 cycles for the 280-block `dd` (both invocations, same
count); 27,779-byte archive for 143,360 bytes of image. Box run: the
box's verilogapple checkout predates spec-12 (259b836, operator's
update pending, docs/FLOPPY-E2E.md's own Box section); `check-floppy`
is the one expected red there until that lands, everything else in
the sweep is the real signal.

**The other direction landed 2026-09-29, docs/UNPACK-E2E.md, this
task's base `b61abb5`.** `check-unpack` proves real `.SHK`/`.SDK`
archives fetched from public Apple II archives (`fixtures/
PROVENANCE.md`) unpack onto a running maux: leg A, `nulib2 -x` two
real freeware `.SHK` archives straight onto the hard drive, all eight
records byte- and type/aux-exact against a second independent NuFX
reader (a2til); leg B, a real ProDOS `.SDK` imaged onto a spare
SmartPort unit with `dd ... conv=notrunc`, `ls`'d and `cp`'d back
(byte-identical); leg C, a real DOS 3.3 `.SDK` imaged onto a unit and
BOOTED standalone on slot 6, reaching "SKIP THE INTRODUCTION? (YES OR
NO)" from a disk maux itself wrote. It found and fixed two REAL bugs
in `nulib2 -x`'s disk-record path that no earlier gate (whose own SDK
fixture happened to carry a correct `thread_eof`) could have
exercised: (1) an old P8 ShrinkIt disk record's in-header name may
carry the high-bit-ASCII display convention on every byte (measured:
DEMOPROG.SDK's "DEMO.PROGRAM"), which is not a legal ProDOS pathname
character and would make `CREATE` refuse it -- fixed by masking bit 7
in both of `nulib2arc.s`'s `NAMEBUF` copy loops (`RDNAMEHDR` and
`RDFNTHRD`); (2) a disk thread's own `thread_eof` is UNRELIABLE in
the wild -- measured truncated (107,008 of 143,360 bytes, DEMOPROG.SDK)
and zero (XMASADV.SDK, which then made `nulib2 -x` report a false
"damaged compressed stream") -- fixed by deriving the true byte count
from `extra_type * 512` (the one block size every disk archive here
uses) instead, the same ladder a2til's own reader already applies.
Both fixes together cost 4 bytes (name) + ~20 bytes (size) of
`nulib2.bin`'s `$BF00` arena wall (docs/NUFX.md slice 8's own "arena
wall" section); margin measured 50 -> 46 -> 11 bytes, still green.
Measured facts recorded in docs/UNPACK-E2E-NOTES.md: ProDOS re-reads
a SmartPort unit's volume directory on open with NO remount needed
after a block-level `dd` rewrite (no stale block-2 cache observed on
this build); `nulib2 -x` cycle counts (VBLSET.SHK 11.8M, SLOTSCAN.SHK
23.0M, DEMOPROG.SDK 126.0M, XMASADV.SDK 134.4M); all three teeth
(`--teeth-corrupt`, `--teeth-order`, `--teeth-type`) seen doing their
job and reverted for the shipped gate.

**`ls /`, `ls /dev`, `cd /`, `cd /dev` SHIPPED 2026-09-30
(docs/DEVFS.md), this task's base `9d8990c`.** `check-devfs` (5/5
cases) proves: `ls /` lists every online volume with NO Disk ][
access (verified by an unmoved `disk2_state` across the call --
`SYS_DEVLIST` reads DEVLST directly and `SYS_ONLINE` is per-unit-only,
per a mid-task operator ruling that replaced the original single-
`ON_LINE(0)` design, "never poll a 5.25-inch drive to list"); `ls
/dev` lists the fixed device names plus one sNdM entry per online
unit including floppies, with a BLK/CHR type column in `-l`; `cd /`
and `cd /dev` admit the two synthetic directories (`PRC_SYNAPPLY`,
kdevblk.s) and relative lookups inside them; `cd ..` from either
reaches `/`; a floppy-less reboot drops `s6d1`/`s6d2` from `/dev`; and
`cat`/`ls` on either synthetic path fail exactly like a missing file.
Four new/moved kernel routines (`PRC_DEVLIST`/`PRC_ROOTLIKE`/
`PRC_SYNAPPLY`/`PRC_ONLINE`) are segment-resident (kdevblk.s), reached
by flat `KSEG_CALL` trampolines in the play-only `procdev.s` with
ERR_NOSYS/carry-only stubs in `procdevs.s` for the ~31 non-play
kernel harnesses -- the same shape `PDEV_TRYBLK_G`/`PRC_BLK_RD_G`
already used. **MAUXPLAY.SYSTEM's flat headroom against
`PT_HOLD_HEADROOM_FLOOR` is 226 B, 30 B short of the 256 B floor --
not closed by this task** (docs/DEVFS-NOTES.md names the exact
re-check command and the sanctioned next target, procbye.s's own cold
paths). `KNOWN_OVERRUN` raised for `MAUXEXPR.SYSTEM` (721 -> 771) and
`MAUXEDTEST.SYSTEM` (425 -> 475), +50 B each, unconditional dispatch
glue in every kernel image that links procfile.s/procfile4.s/kdisp.s.
**The task's own hardest finding did not match its own spec**:
docs/DEVFS.md's kernel-side `PRC_DOTDOT`/`PRC_ROOTLIKE` ".." mechanism
is correct but UNREACHED by `sh`'s `cd` builtin, which resolves ".."
in userland (liba's `MKPATH`/`MKP_POP`) before the kernel ever sees a
raw ".."; the actual bug and fix were in `MKP_POP` itself (a stale
"volume root == pseudo-root" clamp, from before maux had a level above
a volume) -- see docs/CD.md's 2026-09-30 addendum and
docs/DEVFS-NOTES.md for the full trace. Three gate teeth (the Disk ][
skip in `RD_READROOT`, the case-fold in `RD_FOLD`, the DSSS nibble
mask in `PRC_DL_BODY`) run red then reverted this session.
