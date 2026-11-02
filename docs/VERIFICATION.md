# Verification and evidence

Status: LIVE, 2026-09-19. The Makefile's target lists are the executable
authority. This guide describes their current scope, not a claim that all
targets pass at the current worktree.

## Choose the right check

| Command | What it covers | What it does not establish |
| --- | --- | --- |
| `make check-deps` | Locked dependency/tool identities, including emulator binaries | System correctness or a clean-host build |
| `make check-man-image` | Build-roster manual coverage, source/render checks, all staged pages and licence notices | Exhaustive semantic verification of the prose |
| `make check-ascii` | HACKING.md's tree-wide ASCII rule over every tracked text file, with declared high-bit ProDOS exemptions | Anything about the content of those files |
| `make check-all-cross-par J=4` | Ordinary cross sweep, including native NAS gates, selfmake image construction and (since 2026-10-18, c2da9625) the full `check-nas-selfmake` execution | The legacy REL/selfmake gates (check-librel, check-librelas, check-relink, check-selfmake: red by the retired assembler windows; deleted 2026-10-18, c2da9625) |
| `make check-all` | Complete canonical ordinary target list | Optional native CPU tests, release-image reproducibility or physical support |
| `make check-nas-selfmake-image` | Complete staged world graph, capacity checks, NAS storage-model checks, and `check-nas-libpath` (every `ld -l` resolves to a directory that holds REL members) | Execution of that graph (check-nas-selfmake does that) |
| `make check-nas-selfmake` | Guest make, 91 staged-unit + 1 kernel byte oracles (88 UTILS, `ld`, `proshimcr`, `proshimpg`), empty dry rerun, allocation-failure/warm-reuse check | NAS compiling itself, a closed bootstrap, or `as` (the one UTILS entry pinned out) |
| `make check-full` | The release disk (`build/full.po`) audited from its raw bytes by a reader that shares no code with the builder; booted on the fast backend (cycles to the prompt against play.po's); the whole roster on PATH; `hello, world` and a `bye` tenant built ON maux with `nas` and `ld`; `make -n` of the staged world | Physical hardware, the RTL backend, any controller's acceptance of a 32 MB volume, the real world rebuild on this layout (check-nas-selfmake does that on the test layout) |
| `make check-nas-native` | Independent CPU tests of canonical NAS native code, using ACME and py65 | Whole-system or hardware qualification |
| `make check-release-image` | Two release-disk (full.po) builds, and the play.po under them, agree across different host time zones | A clean-checkout rebuild of every input or any test-suite pass |
| `make check-demos` | Every demo in `site/demos/` in gate mode (`scripts/demo_record.py`): the script that films a screencast, run as assertions on a copy of the image the demo names (the play image, or `full`, the release disk, for `hello`, whose Makefile and `hello.s` are also compared with the lesson's own files and whose `hello` is checked for BIN type and `$0800` aux_type on the host). One `check-demo-NAME` per demo, so a red one names itself. Each demo is run on EVERY display it declares, and the runs of one demo must have sent the same keys and shown the same text at every checkpoint, or the gate is red and names the first difference. Includes `check-demo-fedgrep` (W3: `grep.sh` typed into vi, run on the Federalist Papers, `cmp` of its output with the real `grep`'s silent, then over the papers headed MADISON with `xargs`) | That the video encodes (no `screen_image`, no ffmpeg here), or anything about a demo nobody has written yet |
| `make check-recorder` | The recorder itself, in record mode with `--no-encode`, so it runs on the box: same assertions as gate mode; frames == emulated duration x 30 within one; one seed twice gives identical frame-hash sequences and another seed does not; key-strip pixels on exactly the frames a key is live; the PNG decoder against an independent decode and an independent encoder across all five row filters, with each unfilter broken in turn; `fast(16)` badge and cycle counter; the popover box on exactly the frames of its window and nowhere else (and a glyph the font lacks raises); a wrong `expect_text` leaves nothing behind; the planted `mygrep` (fixtures/demos/mygrep.py) red with `grep`, and with `cmp`, replaced by `cat`; the UltraTerm display (scripts/demo_ut.py): a `ut` record's frames read back through the card's own character ROM equal the screen text, the $C0B3 attribute register, cursor modes, nine-dot cell, RA wrap and display start drawn as the manual has them, one frame size for both displays, files side by side, the two displays disagreeing on keys or text goes red; teeth: a character-ROM offset one row off, an ignored inverse attribute, an ignored highlight and an always-lit ninth dot each turn a row red; the 720x432 picture area (the updated card's R9=8 doubled scan lines; the original card's interlaced 16-raster rows, and R9=$0F, kept at 384 and centred; oversize cropped); both card revisions (original v1, the one filmed, and updated v3) through their own pinned character ROMs and firmware, the v3 ROM on a v1 screen reading back wrong, and a CRTC that is not the revision's format-4 entry refused; the `-ut` stamp naming the revision (`ut_revision`), the v1 firmware or chargen staling the `-ut` film only, and a stamp of the wrong revision going red; the recorder's `//e` screen is the raw machine screen, so a `man sh` patched on the guest's image copy (a plain word, then an emphasised one, of the first screenful, taken from the page itself) turns `man` red on both displays; the displays disagreeing on what `vidmode` prints goes red. The demo images are byte-deterministic (scripts/prodos_dates.py, the one shared timestamp module): five images built twice under two faked clocks and two time zones are identical, with a tooth that the same builds without the date normalisation differ; a read-only scan finds any entry of play.po, full.po (when built) or a demo image that is not at the declared timestamp (about a tenth of a second; a full.po rebuild needs an emulator and stays in check-release-image). `make check-ut-render` (Mac only, run by `make demos`; SKIPs without g++ or the verilogapple source) proves the renderer against verilogapple's own on 2,500+ random card states of both card revisions (each through its own ROM), the ninth dot and interlace exact, with an always-lit-ninth-dot tooth and a tooth that each revision drawn through the other's ROM is caught | The encoders, ffmpeg, or how a video looks (`make demos`, Mac only, not in any sweep) |
| `make check-plasma-examples` | Lesson L6 is David Schmenk's bytes: `examples/hellopla/hello.pla` and `src/plasma/inc/cmdsys.plh` equal his files at the PLASMA commit `dependencies.lock.json` pins; the cooked `HELLO` (`build/hellopla.cut` and the file staged on `build/full.po`, BIN $0800) equals a fresh xplasm (-AMW) + acme + plascut cook of the PINNED hello.pla; and /usr/inc/cmdsys.plh and HELLOPLA/hello.pla READ BACK FROM build/full.po equal the pinned bytes in the disk's text convention (D4; the image is required). Seen red on a changed byte in our copy (D1) and in the disk's header (D4) | That plasm compiles it (check-examples l6 and check-plasm-full do) |
| `make check-examples` | Every lesson of /learn/ typed on build/full.po (native 80 columns, clock off, one fresh boot per lesson) a key at a time: vi writes a TXT script and it runs; nas, ld and liba build hello; nas's diagnostics for an unknown label and a syntax error; the upcase filter in pipes; count, each and mygrep typed with cat and cmp-ed against the disk; make, make -n, silence on the second make; HELLO.SYSTEM and LS.SYSTEM run under bye with their screens read DURING the window and `make test`'s cmp silent. Asserts every output's content and order; writes build/examples/ID/session.txt for the pages | Whether a lesson reads well; a never-QUITting tenant (described, not run); the minute-resolution make rule (clock pinned off) |
| `make check-site` | Builds the website (`make site`) and holds it to account: a placeholder with no fact, a fact whose source file is missing, a page naming a demo with no file in `site/demos`, a `repo:` link to an untracked file, a broken internal link or fragment in the output, a root-absolute link, non-ASCII in `site/`, a link to the LAN-only Forgejo, a `src:` comment naming a missing file, and (full build) a roster command with no man page, a stub without its badge, a licences page without the Caldera and Berkeley notices. Its self-test plants each of those (and localhost links, css url() and srcset, extensionless src paths, a watch page naming no demo), and for every film in `build/demos` that the build would publish: an mp4 frame size or poster size other than the one the recorder declares or unlike another film's, a webm, coded size, pixel aspect or display matrix that is not the declared one, a demo with no film files once any exist, a film with no `NAME.stamp.json` (or one copied from another film), and a stamp whose sha256 of the demo script, the disk image, any source file the recorder loaded, the verilogapple binaries and ROMs, the ffmpeg version or the film's own files no longer matches, or that was recorded with another seed, `--setup` or the host clock (`scripts/demo_stamp.py`; hashes, never mtimes; `make site` runs the same check whenever films are present) in a scratch copy and requires each to go red, and builds a copy with no .git (the box) green | Whether a sentence on a page is TRUE: it checks that the source named in the comment exists, not that it says what the page says; how the pages look (look at `make site-serve`) |
| `make check-posix` | The selected conformance suites and their named exceptions | Unqualified POSIX conformance |
| `make check-mame` | Separate independent-emulator checks, with additional prerequisites | Physical-card validation or coverage of the whole canonical sweep |

`make check-man` is the lighter source/render-only manual check. The image
check is in the ordinary sweep; `check-play` separately exercises live
manual lookup, paging and return to the shell.

`check-librel`, `check-librelas` and `check-relink` are RETIRED from
`check-all` by the operator ruling of 2026-09-20, and `check-all-cross` is
now the same list as `check-all` (the name is kept for existing scripts and
habits). All three failed on nothing but the superseded assembler's source
window -- ten kernel/regex modules over real Merlin-8's 41,215-byte buffer,
`REGEX` over `as`'s 16,126-byte budget -- so keeping them as blockers priced
every kernel edit at a mechanical module split, to defend a capability the
2026-09-08 ruling had already given up.

Say plainly what that gives up: **nothing now asserts that real Merlin-8
could assemble the whole kernel from staged source, and that claim should not
be made.** What `as` is still for is gated and is stronger than a capacity
model -- `check-as` runs `as` inside maux over four modules and requires
merlin32-identical objects, including `build/asbigmod.s` at 16,127 B, the
exact maximum its window admits, with 16,128 proven to fail. `check-ascore`,
`check-ascore-warm`, `check-stagebin` and `check-strip` remain in the sweep.
All three retired targets, and `check-selfmake` with them, were DELETED
2026-10-18 (RULINGS-1): the targets, `build_librelas_image.py` and the
dedicated drivers are gone; `check-nas-selfmake` is the replacement.

The box variants exclude `check-deps`, `check-boot`, `check-e2e`
and `check-e2e-fs`, whose oracle or tier is the Mac. Check the actual Makefile lists rather than old summary
messages; host differential oracles and available emulator tiers differ.
Use the provided parallel driver rather than independently launching sweeps
against one build directory: several gates and builders share mutable images.
It runs under `$(SWEEP_SH)`, default `bash` -- as of 2026-09-20, because
invoking `scripts/sweep_par.sh` through macOS's `/bin/sh` (bash 3.2.57)
exited 1 with NO output for any target list, so the parallel sweep had never
actually run on the Mac while this page recommended it. Override `SWEEP_SH`
if your `/bin/sh` is modern; do not use `zsh`, which runs the script but
collapses the target list into a single word.

## Preserve evidence

For a candidate, record:

1. Source commit and `git status --short`; a dirty-tree run is useful but
   cannot stand in for a clean tagged revision.
2. Dependency-lock hash, `check-deps` output, host identity and emulator tier.
3. Exact command, exit status, complete summary and per-target logs. The
   ordinary default `build/checklogs/` is reused, so give candidate runs a
   distinct `CHECKLOGDIR` or archive their logs before another sweep.
4. NAS/image hashes, world composer plan and byte-oracle results. Staged
   recipe counts are not executed-command counts; NASLOG reports can be
   interleaved with make output and must not be counted only at line starts.
5. Every failure, exclusion and known defect, with its disposition. Never
   present the output of a later isolated rerun as the original full sweep.

For example, `make check-all CHECKLOGDIR=build/checklogs-candidate` gives
the canonical sweep a separate log directory; retain its outer summary and
exit status as well. Logs under `build/` are local artifacts, not automatically
included in a release bundle.

## Current evidence boundary

The saved 2026-09-18 canonical sweep at `828309c` ended with five failed
targets: `check-posixutil`, `check-e2e`, `check-librel`, `check-librelas`, and
`check-relink`. It is now archived in the tree, with its summary, the five
failure logs and a per-target disposition (see [evidence/](../evidence/README.md)).
It originally lived only in `/tmp` on one laptop while this document cited it,
which is why [evidence/](../evidence/README.md) exists at all.

Triaged 2026-09-19, from those logs: three of the five (`check-librel`,
`check-librelas`, `check-relink`) are one undone ruling about legacy
Merlin-8/`as` source-window capacity, not code defects. `check-e2e`'s three
cases were a stale ratchet entry, not a `wc` defect, and are fixed.
`check-posixutil`'s single non-gap divergence was a real `ls -R` defect, and
is fixed. Neither fix greens that sweep retroactively: no complete canonical
green exists at any revision yet, and the candidate carrying these fixes has
to run the whole list itself.

The denominator behind "85 utilities": the native world stages 85 of the 86
`src/bin` programs that have a build artifact, and `as` is a PINNED skip --
by the 2026-09-01 ruling that `as` wraps the vendored Merlin core and nas is
its replacement, so assembling `as` with nas is circular. The skip is not a
silent one: `build_nas_librel_image.py`'s `assert_complete_world` refuses any
skip set other than exactly `{'AS'}` and any util count below 85, so a
utility cannot drop out of the world unnoticed. Say "85 of 86, `as` pinned",
not "85 utilities", when the sentence could be read as full coverage.

The candidate sweep at `983ae9c`, 2026-09-20, is **102 of 104** -- the first
run of the current list, archived with both reds and their dispositions (see [evidence/](../evidence/README.md)).
`check-idle` was its own sample budget outrun by the faster assembler and is
fixed; `check-jobctl-a` is an open kernel defect (an orphaned subshell takes
the kernel into `KRN_BRK_TRAP`, halting the machine). Both messages were
misleading before this pass, which is the more useful lesson: a gate's failure
text is a claim about the system, and two of them were wrong about which
subsystem had failed.

The 2026-09-19 promoted NAS and cumulative remeasurement do have independent
full-world byte passes at 8.30B fast-emulator cycles. Those
reports (not published) explicitly do not claim a complete canonical sweep.

The clean Debian host proof in [HOST-PROVISIONING.md](HOST-PROVISIONING.md)
is for `a04c49f`, not the later promoted NAS worktree. Repeat the appropriate
clean-host build for the eventual release candidate.

## Interpret results narrowly

Byte comparison against an independent assembler is stronger than comparing
two runs to each other. A repeat pair can reproduce the same wrong answer.
Require demonstrated mutation/sabotage sensitivity where practical. Fast
emulator behaviour is not physical-hardware evidence; use the
[support matrix](SUPPORT.md) for that boundary.

The pinned emulator can emit a mutex exception at shutdown. Do not suppress
it or infer success from it. The NAS reports separately establish completion,
readable images and host byte checks; other runs need their own evidence.

Library notes: `learning:01M0PG8GD5A83BFKWFV0TJCSPP` documents the measured
blind spot of repeat-only poison tests; it motivates the independent-oracle
distinction, not a new claim that every gate has such an oracle.
