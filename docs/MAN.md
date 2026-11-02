# Manual pages: what one must contain, and who owns it

Status: GOVERNANCE, updated 2026-09-19. Operator's source-selection policy:
use the oldest publicly available, generously licensed manual page as the
basis, then modify it forward as necessary for maux. A mix of V7 and early
BSD pages is expected. Section 7 replaces the earlier advice to prefer
newly written pages over adapting historical ones.

Historical prose is the starting point; the current implementation is the
behavioural authority. Preserve the useful period explanations and examples,
and correct the parts that do not describe this build.

## 1. Who the reader is

A stranger with the disk, sitting at the machine, typing `man cut`.
Not a maintainer with the source tree open. Everything below follows
from that: the page is the only documentation that ships ON the
volume, so anything a user needs at the keyboard belongs here and not
in `docs/`.

Corollary, and it is the rule that decides most arguments: **a page
describes what THIS build does**, never what POSIX says in general and
never what some other Unix does. Divergences are the interesting part
and get stated, not hidden (sec 5).

## 2. Command pages, stubs and notices

| kind | count | what it is |
|---|---:|---|
| implemented utility | 85 | all 83 Makefile utilities plus separately built nas and ld |
| not-applicable stub | 63 | a POSIX utility ruled out, and why |
| licence notices | 1 | required notices, readable with `man licenses` |
| house tool | category, not an additional count | maux-specific tools also need pages; a historical namesake is not automatically a suitable source |

Coverage repair, 2026-09-19: 46 missing command pages added; the 149-page
corpus now covers 85/85 build-roster commands and 78/78 play-image commands.
Shell builtins are covered in sh(1). Stub count is not command coverage.
Four skeletal pages (cp, mv, ls, rm) were also completed. See the
[source register](man/SOURCES.md) for ancestors, licence decisions and the
limits of this content audit. Counts are checked against the build roster,
not accepted from this paragraph.

A stub is a first-class page, not an apology. `man ar` must answer the
question rather than say "no manual entry", because "no manual entry"
reads as an oversight and the omission is a decision. Sec 6.

## 3. Required shape

`.TH NAME 1 "Month D, YYYY" maux`, then in this order, omitting what
does not apply: `NAME`, `SYNOPSIS`, `DESCRIPTION`, `FILES`,
`SEE ALSO`, `DIAGNOSTICS`, `BUGS`. V7 man(7) macros only -- `.B`,
`.I`, `.BR`, `.IR`, `.TP`, `.PP`. No `mdoc`, no extensions mandoc
would accept but `nroff` would not (sec 4 explains why both matter).

Two house conventions the corpus already keeps:

- **A leading `.\"` comment block** naming the file, whether the page
  is original or derived (sec 7), and where it is rendered and staged.
  It is the only place a reader of the SOURCE learns the page ships.
- **`FILES` names the staged page itself** (`/usr/man/TTY  this
  page`). Small, but it teaches the volume layout to someone who has
  only ever typed `man`.

`DIAGNOSTICS` states the exit statuses as numbers. Every utility here
has them and a script author needs them.

## 4. ASCII, 64 columns, and why both

The build renders with the lock-selected
`mandoc -Tascii -O width=64` (the Makefile's `man-pages` rule). The bootstrap
builds mandoc 1.14.6 from its hash-verified source archive, and `check-deps`
requires a byte-exact render probe. The V7 man(7) macro subset remains the
source contract; it keeps the pages portable as source even though release
bytes deliberately have one renderer.

- **64 columns**, not 80: this leaves margin on the 80-column console.
  It does not fit a 40-column console without wrapping; check that display
  separately instead of treating the render width as a readability proof.
- **ASCII only**, in the source and therefore in the render. The
  console is a 7-bit VT102 and the keyboard is a //e's (HACKING.md):
  an em-dash paints as `b` through `tip` and cannot be typed back.
  Use `--`, `->`, `<=`. `check-man` checks sources and rendered ASCII.

Check a new page's render before committing it. A macro mandoc
silently drops can leave a paragraph missing on the volume while the
source looks fine.

## 5. Divergence is content

Where this build differs from POSIX or from the host, the page says
so plainly, in the page, not only in `docs/POSIX-GAPS.md`. Existing
examples worth copying: `exec` runs and then exits because there is no
exec syscall; `times` reports elapsed in field one and structural
zeros in the rest because there is no per-process accounting; `grep`
is BRE-only by ruling; `more -A` is a private flag.

The ledger (`docs/POSIX-GAPS.md`) and the scoreboard
(`docs/POSIX-CONFORMANCE.md`) are the maintainer's record. The page is
the user's. **Both, not either** -- a divergence recorded only in the
ledger is invisible to the person it affects.

## 6. The stub contract

A stub's `DESCRIPTION` is two to four sentences: the tool is not
provided, and the mechanical reason. `SEE ALSO` names the substitute
when one exists (`ar` -> `ld`, `unlink` -> `rm`) and is omitted when
none does.

**One wording per reason group, reused verbatim.** The 63 stubs use
about ten: no accounts; no scheduler or IPC; no network, mail or
print; C locale only; filesystem semantics ProDOS lacks; no C
compiler; SCCS lives in git on the host; no compression; no terminal
database; no Fortran carriage control. Reusing the sentence makes the
corpus read as one voice and makes a new stub a lookup rather than a
composition.

**A stub must never claim more than `docs/POSIX-GAPS.md` sec 5 does.**
If the ledger says "not applicable" and the page says "impossible",
the page is wrong. Move the ledger first if the reasoning has changed.

## 7. Historical source first, then adapt forward

For each implemented command:

1. Find the oldest publicly available page for the relevant command whose
   licence permits the intended reuse, modification and redistribution.
   Prefer generously licensed historical sources. V7 and early BSD are the
   expected starting collections, not a requirement to force every page
   into one release. Use an earlier suitable page where available; use early
   BSD for commands or useful descriptions that arrived later.
2. Record the exact edition/release, archive URL and source path, plus the
   applicable licence and notices. Keep an identifiable upstream revision
   or source checksum so another maintainer can recover the starting text.
   If choosing a later source, state why the earlier candidate was unsuitable
   or could not be located/licensed. A reasonable documented search suffices;
   do not turn "oldest" into an unbounded archaeology task.
3. Adapt that page to the actual maux command. Retain useful explanations,
   organisation and examples; remove or explicitly qualify unsupported
   behaviour. Add implemented options, ProDOS semantics, limits, exit statuses
   and examples absent from the original. Check every command example.
4. Preserve upstream attribution and required notices. Identify maux's
   modifications and their date in the leading `.\"` source comments.
   An adapted historical page remains derived, even after extensive edits.
5. Write an original page only where no suitable, generously licensed
   predecessor is found, or where the command is genuinely maux-specific.
   Record that choice and its reason. Unavailable-command stubs can remain
   original explanations of the omission; do not import a full manual for
   a utility the system does not provide.

**Public availability is not a licence.** Verify the selected text's terms,
not just the archive's reputation or the operating-system family name.
The [Caldera grant](https://www.tuhs.org/Archive/Caldera-license.pdf), retained
in `docs/man/CALDERA-LICENSE`, names Research Unix V1-V7 and 32V. It is not
a blanket substitute for Berkeley or other contributors' notices in a BSD
page. Check those separately; the
[Berkeley copyright and amendment](https://www.freebsd.org/copyright/license/)
are useful references, not automatic clearance for every archived file.

Required notices must accompany the distributed manual as well as its source
where the licence requires it. Roff comments disappear during rendering:
keeping a notice only in a `.\"` block is not, by itself, evidence that the
bootable image carries the required material. Verify the release packaging.
Do not silently relabel imported prose as MIT or assume that paraphrasing a
modern manual makes it original.

For existing pages, retain known provenance rather than inventing a historical
pedigree. Audit unattributed or incomplete pages as they are repaired. The
policy is to build on the historical manual, not merely imitate its style.

## 8. Naming, and the ceiling nobody has hit yet

The staged name is the upper-cased stem: `docs/man/cut.1` ->
`/usr/man/CUT`. So a page name must be **ProDOS-legal and at most 15
characters**: first a letter, then letters, digits and periods. The
longest today is `uncompress` at 10, so there is room, but a future
tool with a long name inherits the limit (`docs/LAYOUT.md`, gated for
manual pages by `check-man`).

## 9. Build, staging, and cost

**A new page needs no wiring.** The Makefile globs `docs/man/*.1` and
`build_play_image.py`'s `stage_man_pages` stages the corresponding render
for each current source page. Missing renders fail; orphaned `.TXT` files
from removed sources are ignored, so stale pages cannot ship by accident.

It is not free, though. Each page is at least one block on the play
volume, and the 63 stubs cost about 110 together. `build_play_image.py`
prints the free count and `report-volumes` flags a tight volume.
**Check it after adding a batch**, and remember that a derived image
may not want them at all -- `build_nas_real_image.py` drops the whole
directory because it never invokes `man`, which is why its volume
stopped overflowing. The 2026-09-19 coverage repair left only 46 free blocks
on the old 800K image. The operator then enlarged the play/release image to
4 MiB (8192 blocks), with 6637 blocks free (about 3.24 MiB), and the
release disk built from it is 65,535 blocks (docs/FULLDISK.md). Capacity is
a packaging choice, not a floppy ceiling.

## 10. What man(1) itself does, and does not

`man NAME` uppercases the name, opens `/usr/man/NAME`, and pages it
through `more -A` (the alternate screen, so quitting restores the
shell's screen -- `docs/VI-ALTSCREEN.md`). A leading numeric section
argument is accepted and ignored: this tree ships one section.

**There is no index, so there is no `apropos` and no `whatis`.** `-k`
and `-f` are named as gaps rather than faked. Anything that would
require searching across pages does not work, which is another reason
each page must stand alone.

## 11. Gating

`make check-man` derives the command roster from Makefile UTILS plus the
separately built nas and ld, rejects missing pages or unavailable stubs for
implemented commands, checks required sections, ASCII, ProDOS page names,
provenance headers and current nonempty renders. Its mutation tests prove
that missing pages, false stubs, absent sections and missing licences fail.

`make check-man-image`, included in the ordinary sweep, additionally verifies
the complete image page roster, TXT metadata and current staged bytes. An
independent plain-text comparison checks that the overstrike-to-SGR
conversion preserves the prose. `check-play` drives `man man`, `man sh`,
`man nas`, `man vi` and `man licenses` through the live pager and back to
the prompt. `check-posixutil` retains its redirected/stub man cases.

**Not gated, and worth knowing**: nobody checks that a page's content
matches the binary's behaviour. A flag that lands without its page
edit is invisible to every gate. The discipline is in the checklist
(land the flag, retire the ledger row, edit the page), not in a test.
