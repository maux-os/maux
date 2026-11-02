# Documentation map

Status: LIVE, 2026-11-02. Start here when a design diary and the current
system appear to disagree. An old `NEXT` is not an assignment.

## Current entry points

| Question | Authoritative starting point |
| --- | --- |
| What works, what remains, what comes next? | [Project state](PROJECT-STATE.md) |
| How do I build and boot it? | [Repository README](../README.md) |
| Which inputs and host tools are needed? | [Dependencies](DEPENDENCIES.md), [host provisioning](HOST-PROVISIONING.md), [toolchain and test rig](TOOLCHAIN.md) |
| Which checks do I run, and what do they prove? | [Verification](VERIFICATION.md) |
| Does a gate still pass if the guest gets faster or slower, and when is waiting a lie? | [Gate predicates](GATE-PREDICATES.md) |
| Does a gate's check actually bite? | [Teeth runners](TEETH.md): sabotage the code, watch the named rows go red, restore byte for byte |
| How do I use, build or change NAS? | [NAS](NAS.md) |
| How are user-facing manual pages sourced and maintained? | [Manual-page policy](MAN.md) |
| How do I package a release? | [Release procedure](RELEASE.md) |
| What machines and limitations can I claim? | [Support](SUPPORT.md), [known limitations](KNOWN-LIMITATIONS.md) |
| What are the architectural invariants? | [Architecture reading guide](ARCHITECTURE.md) |
| What does the repository tree look like, host and guest? | [Layout](LAYOUT.md) (one tree, every name legal on ProDOS) |
| What did the last full sweep actually say? | [Retained evidence](../evidence/README.md) |
| What are the contribution conventions? | [Contributor guide](../HACKING.md) |
| Which ProDOS does maux boot, and why? | [ProDOS version](PRODOS-VERSION.md) |
| What does maux deliberately do differently from its period? | [Anachronism register](ANACHRONISMS.md) |
| What is `/etc/issue`, the boot splash? | [Issue](ISSUE.md) |

## Subsystem contracts

- Kernel interfaces: [syscalls](SYSCALL.md), [memory map](MEMMAP.md),
  [fork](FORK.md), [scheduler and timer](SCHED.md),
  [signals](SIGNALS.md), [job control](JOB-CONTROL.md),
  [process I/O](PROCIO.md), [io_buffer lending](IOBUF-LENDING.md),
  [resource limits](LIMITS.md), [the virtual root](VROOT.md),
  [the language card](LANGUAGE-CARD.md), [kernel label ledger](KLEDGER-TABLE.md),
  [kernel cold segment](KSEG.md)
  (LC bank 2, `check-kseg`), [/dev block devices](DEV-BLOCK.md)
  (`check-devblk`), [NuFX archives](NUFX.md) (`.SDK` disk archives,
  `check-nulib2`), the floppy round trip (a real 5.25" disk through all three,
  `check-floppy`), real archives from the wild unpacked onto the machine
  (`.SHK`/`.SDK` fixtures from public archives, `check-unpack`), [`ls`/`cd`
  on the pseudo-root and /dev](DEVFS.md) (synthetic directories, no
  polling a 5.25" drive to list, `check-devfs`).
- Interactive system: [console](CONSOLE.md),
  [the VT102 target](CONSOLE-VT102.md), [multi-mode consoles](VIDMODE.md),
  [serial and `tip`](SERIAL.md), [POSIX conformance](POSIX-CONFORMANCE.md),
  [POSIX gaps and the open shell divergences, G1..G28](POSIX-GAPS.md),
  [`ex`](EX-DESIGN.md) and [`vi`](VI-DESIGN.md) design,
  [person-like terminal tests](E2E-TERM.md), [userland and liba](USERLAND.md),
  [`cptree`](CPTREE.md).
- Hardware and hosting: [RamWorks reset behaviour](RAMWORKS-RESET.md),
  [`bye`, suspend and run a ProDOS program](BYE.md),
  [`/dev/loop`](LOOP.md), [MAME as the second rig](MAME.md).
- Native toolchain: [NAS](NAS.md), [linker](LD-NATIVE.md),
  [make](MAKE-POSIX.md), [PLASMA port](PLASMA-PORT.md),
  [plasma cutter](PLASCUT.md), [REL object format](REL-FORMAT.md),
  [NAS two-pass storage](NAS-TWO-PASS-REFACTOR.md).
- Performance: [NAS](NAS.md) carries the current measurements;
  [PLASMA performance guide](PLASMA-PERFORMANCE-GUIDE.md).

Subsystem documents can contain dated amendments. Check the source and
named acceptance gate before treating an older limitation as current.

## Retained gate evidence

[evidence/](../evidence/README.md) holds the summary of each run worth citing,
with its outcome. It exists because the last full canonical sweep's only copy
was in `/tmp` while this documentation set cited it. A record there says what
a run printed, not that its conclusion still holds.

## Historical material

Dated design and experiment documents preserve decisions and bring-up
history. Their old next-step recommendations are not the current work queue;
[NAS.md](NAS.md) identifies the production assembler path.

**The boot volume was renamed and the root became virtual (2026-10-10,
[VROOT.md](VROOT.md)).**
Every dated document above that says `/BASIC/` was written before it:
read `/BASIC/BIN/X` as `/bin/X`, `/BASIC/MAN/X` as `/usr/man/X`, and any
other `/BASIC/X` as `/mnt/MAUX/X`; the volume is `MAUX`. The live guides
were rewritten; the history documents keep their words. `check-volname`
holds the line.

## Maintenance rule

Put project status and priorities in PROJECT-STATE.md, operating instructions
in the relevant live guide, and dated experiments in their existing reports.
Link rather than copying a changing inventory into several documents.
Record the revision or executable hash, test scope, host/emulator and date
beside a verification claim. Distinguish a target that exists from a target
that passed, and a scoped pass from a complete release qualification.

Keep historical reasoning, but add an explicit dated supersession notice
when it would otherwise misdirect a reader. Do not rewrite architecture to
justify code without checking which side is current.
