# Hacking on maux

Conventions and limits that are load-bearing here. Most of them exist
because something broke once; where a rule looks arbitrary, it is usually
a scar.

## The assembler dialect is narrower than merlin32

merlin32 (locked at v1.1.10) is the assembler of record, and `nas` + `ld` +
`make` is the native build path. But the checked dialect is deliberately
narrower than what merlin32 accepts, because `nas` has to assemble the same
source on the machine itself. Several of these are SILENT on one assembler
and loud on the other, which is why the byte-compare gates stay load-bearing
even at `Errors: 0`:

- **64 characters per line.** Real Merlin truncates past it. `check-modules`
  counts lines over 64 in `src/bin/*.s` against a pin of 0. Comments count.
- **13-character labels**, 12 for a `:local`.
- **No operator precedence and no parentheses.** Expressions are strictly
  left to right.
- **Opcodes match on their first three characters only.**
- **`EQU` forward references** can miscompile silently.
- **A negative `ds` emits nothing**, silently.
- **Cross-zone `:local` references** resolve by whole-file uniqueness in
  merlin32 and break the day a `put` collides. When you add a global label
  to an existing file, the insertion point is a scope decision, not a
  readability one: check which `:local` definitions fall below it. Safe
  spots are the file's textual end, or after the last local of the routine
  you are following -- never "just after the routine that calls it", which
  is where it reads best.

`check-dialect` and the independent `nas`/REL byte gates enforce this.

## ASCII only, everywhere

Every tracked text file, source and docs alike. The console is a 7-bit
VT102 and the keyboard is a //e's: an em-dash in a doc paints as `b`
through `tip` and cannot be typed back. Use `--`, `->`, `sec`, `<=`.

This is gated by `check-ascii` over every tracked text file, with two
declared high-bit ProDOS exemptions and a mutation self-test. It is gated
rather than merely written down because the hand-fold that preceded the
gate came undone within eight days.

## Text encoding has two conventions, and a library that knows both

maux text is high-bit ASCII terminated by `$8D`. ProDOS-standard text is
low ASCII terminated by `$0D`. Both exist on disk and tools must handle
both. Never hand-roll either: `a2til`'s `convert.text_from_host(data,
high_bit=...)` implements both, and `check-encoding` counts the scripts
that still set bit 7 by hand against a shrink-only pin.

Those pins are ratchets. If your change takes a count BELOW its pin,
re-pin it in the same commit with a reason -- a pin sitting above its
measured count silently permits that many new violations, which is worse
than no ratchet at all.

## Use the house tools, and read them first

Disk images go through `a2til`, never Cadius or AppleCommander. But
knowing a tool exists is not knowing what it does: before writing a
pipeline, read that tool's README feature list and `--help`, and ask what
of your intended work it already ships. `a2til mirror` poll-syncs a host
directory into a mounted volume with translation and transactional
passes; it was hand-rolled as a bare image-writer four separate times
before anyone read the feature list.

Generated disk images are never committed.

## Gates

- **`make preflight`** (~30 s) is the front door: the ledger, encoding,
  modules, dialect, ASCII and kernel-image checks. Run it before your
  targeted gate, not after. Most of what it catches -- column overruns,
  encoding debt -- is invisible to every functional gate, so a stream that
  runs only its own gate will report green and still be broken.
- **`make check-all-host`** is the sweep that needs nothing but the
  toolchain -- no emulator, no ROMs. Start here; it is the one that works
  on a fresh clone.
- **`make check-all`** is the full sweep, and most of it boots a machine.
  Never run a hand-picked subset of it and call that a pass.
- A test is not a test until you have seen it fail. Plant the defect it is
  meant to catch and require red; a gate whose teeth were never checked
  tends to be measuring something adjacent to what you think.
- Hardware claims get verified on MAME or AppleWin, or on real hardware,
  and the comment says which and what version.

### What you can run, and what you cannot

maux is an operating system, so most of what there is to assert about it
is what the hardware does while the kernel runs -- and that needs an
emulator driven over a machine interface. The sweep divides three ways,
and it is worth knowing which third you are in before a green convinces
you of anything:

- **The toolchain gates** run anywhere `merlin32` and `python3` do. They
  are every static rule this tree enforces -- the dialect, the column
  limit, ASCII, the kernel-image size ratchets, the two hardware lints
  (`check-lc`, `check-altzp`) -- plus the host side of all three
  differential gates, which is where a conformance bug usually surfaces
  first. `make check-all-host` runs exactly these, and
  `scripts/check_host_sweep.py` proves that list is exactly the set with
  no path to an emulator, so it cannot quietly grow a gate you can't
  run. Three gates need no emulator and are still out of it, because
  they read build artifacts another gate produces -- the gate names
  those three and why, so that exclusion cannot go stale either.
- **The conformance gates** boot a disk image and compare maux's output
  against a host oracle: does `sed` do what `sed` does, does `vi` repaint
  what `vi` repaints. These are the bulk of the sweep. They need an
  emulator with a machine interface.
- **The engine gates** assert what the hardware does -- a soft-switch
  ordering, a scheduler switch count, a language-card bank, an interrupt
  arriving. **Not every gate in this tree has its driver published**:
  these live in `gates.mk`, which is not in the public tree, so
  `make check-all` here runs the gates it has and says so when it starts.
  Their names stay in the Makefile and their findings stay in the docs
  and the source comments, because a comment recording which gate
  measured a cycle count is worth keeping even when you cannot run that
  gate. A reference to a `scripts/check_*.py` you do not have is one of
  those, not a broken link.

The same is true of the docs, for the same reason and with the same
consequence. maux was built in bounded streams, each with a brief saying
what to build and a notes file recording what the work found, and those
two documents are written for the person doing that one piece of work:
they assume the state of the tree that week, the measurements that
prompted them, and decisions taken elsewhere. **Not every document this
tree cites is published** -- the briefs and their notes are not, while
the docs that describe how the system IS are. So a reference to a
`docs/`SOMETHING`.md` you do not have is the same kind of reference as a
withheld gate driver: it records which piece of work settled a question,
which is worth keeping in a comment even when you cannot read that
piece. What a contributor needs is here -- the architecture, the syscall
ABI, the memory map, the console protocol, the toolchain and dialect
rules, the conformance and support matrices, the limitations, and the man
pages. If you find something you need to know that is only in a withheld
note, that is a documentation bug worth reporting: the fact belongs in a
published doc.

A third reference reads like a broken link and is not one. Comments and
design notes cite handles of the form `learning:01M...`, sometimes under
a **Library notes** heading. These point into a collection of verified
hardware and firmware findings the project keeps outside this
repository: a handle records WHERE a fact was settled and by what
evidence, not a document you can open from here. **Not every source a
claim cites is published.** The claim beside the handle always stands on
its own -- it says what the hardware does, in enough detail to check
against a manual or a machine -- and the handle is there so that a
finding can be traced rather than re-derived. If a claim leans on a
handle and does not stand up without it, that is the same kind of
documentation bug as a fact stranded in a withheld note.

So: a green `check-all-host` means the static rules hold and the tree
builds. It does not mean the kernel works. If you are changing kernel
behaviour and cannot boot a machine, say so in the change -- an untested
kernel change honestly labelled is useful, and one presented as verified
is not.

## Behaviour and fidelity are different claims

The emulator used by the test rig has two backends, and the split matters
enough that gates name which one they ran on. The fast backend proves
BEHAVIOUR -- that the code does what it should -- and never hardware
fidelity. A claim about what the HARDWARE does needs the cycle-accurate
backend, MAME, AppleWin, or real iron; verifying the fast backend against
itself proves nothing.

The same care applies to written claims. Notes and comments grade what
they assert: `[fact]` is measured or quoted from a primary source,
`[likely]` is inferred, `[reported]` is secondhand. **Only `[fact]` may be
load-bearing without verification.** If a design depends on a `[likely]`
or `[reported]` claim, verify it first -- and record the result, because
that verification is usually worth more than the design decision that
prompted it.

## vendor/ is never modified in place

Vendored material is a fixed input. Copy it out and transform the copy;
a gate compares the vendored carrier against a lock and refuses a
mismatch.

## Films and lesson pages are keyed to a disk image

Both record the sha256 of the image they ran on, so any change to a
userland binary stales all of them at once. Regenerate in this order --
`make check-examples demos`, examples first -- because `check-examples`
rebuilds images the films boot, and recording first throws the recordings
away. See `site/README`.

`make check-sessions-fresh` (in `preflight` and `check-all-host`) is the
cheap probe for this: it hashes `build/full.po` and reads each lesson
session's recorded sha, so a `make play` or `make full-image` that rebuilt
the disk shows red the same day instead of when `check-site` is next run.

## The engineering notebook

This project keeps a searchable notebook of findings about Apple II
hardware, firmware and tooling, and leans on it rather than on
first-principles reasoning. Three habits are worth copying even if you
never see the notebook itself:

- **Search it before designing against a device.** First-principles
  reasoning about Apple II soft switches is presumed wrong until checked.
  The trigger is any document that tells someone else what to build, not
  just a subsystem design -- a spec written without that check shipped
  three defects the notebook had already recorded, and each was paid for
  again by measurement.
- **Search by the subsystem's vocabulary, not your own framing.** One
  topical query misses findings filed under a device or a symptom name.
  Sweep the concrete nouns: each peripheral, each mechanism, each symptom.
  The same device often has two names, and a search for one will never
  surface the other's documents.
- **Deposit back.** When work verifies, refutes or refines a finding,
  record it -- mechanism and symptom, with the symptom in the title, so
  the next person searching a symptom finds the mechanism. Settled
  knowledge only.

The confidence grades above are part of this: a finding carries its
grade, and only `[fact]` is load-bearing without verification.

## `learning:` citations

Comments throughout the tree cite handles of the form
`learning:01M0...`. These are footnotes into the project's own
engineering notebook, not public URLs, and nothing depends on resolving
them: wherever one appears, the surrounding comment states the substance
it is citing. They are kept because they record which findings were
measured rather than assumed.
