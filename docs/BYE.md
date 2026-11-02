# `bye`: suspend maux, run a ProDOS program, come back

Status: LIVE. `bye` and `bye PATH.SYSTEM` are built (`src/bin/bye.s`,
`byelaunch.s`, `byeres.s`, `src/kernel/kbye.s`, `procbye.s`; user page
`docs/man/bye.1`) and gated by `check-bye`, `check-oftbye`,
`check-rambye` and `check-tenant`. Still unbuilt: a tenant's exit
status (the round trip returns 0; ProDOS has none), a `-k` option,
pinned-file canonicalisation at `bye` time, the read-high loader for
tenants over `$7800`. This document is the design diary, oldest first:
where a later dated section corrects an earlier one (the /RAM dance,
the QUIT pathname, the resident's home), the later section wins, and
the user-facing contract is `bye.1`. The resident now lives at
`/mnt/MAUX/BYERES` (written `/BASIC/BYERES` below: the boot volume's
old name, before the virtual root, docs/VROOT.md).

Operator, 2026-09-14: "the idea would be to save the kernel state and
launch a prodos program such that maux can be restored when the prodos
program quits." The ruling that led here: `kill -9 $$` was refused
(790c0b7) because there was no init (lifted 2026-10-18, RULINGS-1: init
respawns the shell); this is the "bye that does useful work" named in
that ruling.

## What it is for (operator, 2026-09-14)

"Its main point is to enable true testing when you're using maux as a
development environment." The loop is: edit in vi, assemble with `as`
or `nas`, link with `ld`, drive it with `make` -- all under maux -- then
run the RESULT on the real ProDOS 8, not under the proshim, and come
back to the editor and the shell exactly where they were. That is the
test a ProDOS program actually needs, and today it means rebooting.

Two consequences for the shape below: `bye` must be scriptable (a
`make test` rule that ends in `bye MYPROG.SYSTEM` is the target user),
and it must hand the program's outcome back to the calling shell as an
exit status, so a script can branch on it.

## The mechanism the machine already has

**ProDOS's QUIT call is a hook, and "Bye" programs are its tenants.**
MLI call $65 copies $D100-$D3FF from language-card bank 2 to $1000 and
jumps there; what lives in that window is Apple's dispatcher, and every
program selector (Apple's BYE, Bird's Better Bye) works by replacing it
(ProDOS 8 TRM, artifact `d82965d8...`, "QUIT call"). So maux's `bye` is
that window: a 768-byte resident that gets control on EVERY QUIT,
including the one the launched program makes to leave -- which is the
"restore maux" moment, for free.

**The save half has precedent in the commons.** EDASM saves exactly that
language-card bank to EDASM.SWAP before taking it over, which is why its
swap file disassembles as $1000-based 65C02 with `STZ $03F2` in it
(`learning:01M1X0F064TX9PZD2JFVEX9MJJ`).

**/RAM is the hazard.** ProDOS auto-installs /RAM over aux bank 0
$0200-$BFFF -- maux's annex. TN #26's polite-citizen protocol
(`learning:01KW1GTYH4NRG0F8M7AAT6EG9Z`): disconnect at start, reconnect
before QUIT; DEVLST's device byte ($BF) and ON_LINE's unit number ($B0)
differ.

## The shape

1. `bye [PROGRAM.SYSTEM]` (a builtin or a small util): quiesce the tick
   (the mouse-card VBL / whatever timer.s armed) and give back the $03FE
   vector; disable the UltraTerm if it owns the glass; flush stdio.
2. Save the machine: the kernel's main-memory footprint, its language
   card (both banks), zero page and stack, the annex (aux bank 0), and
   the soft-switch state -- into a RamWorks bank ProDOS cannot see. Plain
   ProDOS 8 knows only aux bank 0 (through /RAM); every other bank is
   invisible to it, so a dedicated "save bank" is safe from any program
   that is not itself RamWorks-aware. Process banks stay where they are;
   they are not copied.
3. Install the maux resident at $D100-$D3FF (bank 2) over the dispatcher
   -- after saving the dispatcher, EDASM-style, so a real QUIT can still
   reach it if maux chooses to hand over for good. Reconnect /RAM (TN
   #26), then issue MLI QUIT with the program's pathname the way a
   selector does.
4. The program runs on a machine that is, as far as it can tell, freshly
   booted ProDOS: main memory, /RAM, the language card, all its own.
5. It QUITs. ProDOS runs the $D100 code = the maux resident: disconnect
   /RAM, copy the saved image back from the save bank, restore the soft
   switches and the LC, re-arm the tick, and resume the scheduler where
   `bye` left it. The shell that called `bye` returns from the syscall
   with the program's outcome; every other process never noticed.

## What it costs and what it cannot promise

* **Warm respawns restart cold after a `bye`.** Lazy free's tags
  (docs/STICKY.md) are dropped when `bye` commits (KFIX2 item 4,
  `LZ_DROPALL`): a tenant writes files with raw MLI calls that no
  kernel write hook sees, and mtime cannot see a same-minute rewrite,
  so a program the tenant rebuilt would otherwise respawn with its OLD
  text. The retained banks go back to the free list; the next spawn of
  each program is one ordinary cold load. check-tenant check 7.

* **A RamWorks-aware program eats the processes.** AppleWorks with an AE
  expander uses every bank it finds. `bye` should say so in its manual
  page and offer a `-k` (kill everything first) for that case; a
  save-bank checksum on restore turns "silently corrupted" into a
  refusal with a message.
* **Interrupts.** ProDOS programs do not expect a live IRQ source. The
  tick must be quiesced before QUIT and re-armed after, and the $03FE
  vector handed back and retaken (`learning:01M096X5CNKFNNJW8XND8BA89R`
  on why owning $03FE matters under a hosted kernel).
* **Space.** The resident is 768 bytes; the save image is roughly the
  kernel's footprint plus the annex, one bank's worth. The save bank is
  one fewer process slot while `bye` is out. Slice 1 (2026-09-25): the
  768 bytes are NOT part of the kernel's own on-disk image -- they cost
  real always-resident image bytes there for a few-thousand-cycle-per-
  call blob, which pushed the image past a real ceiling
  (`docs/BYE-SLICE1.md`'s resident section). They live on disk at
  `/BASIC/BYERES` and load into the LC at `bye` time instead.
* **The UltraTerm.** A program that does not know the card writes the
  40/80-column pages; the resident must put the glass back where maux
  had it (VIDMODE V2 owns that state already).

## Sequencing (the original plan; both slices have landed)

First slice: the resident + save/restore of main memory and the LC with NO program
launched (`bye` to the ProDOS prompt and back via a QUIT from the
monitor), gated in the emulator by a marker in a process bank surviving
the round trip. The /RAM dance and a real .SYSTEM launch are the second
slice.

## 2026-09-22: what the primary source says, and what this note got wrong

Read against the ProDOS 8 TRM's own selector section (artifact
`d82965d8...`, pages 86-88) before writing any code. The contract it
states is now distilled in the commons as
`learning:01M34A439TDASMVQNDCX41QGMN`, which the first slice should
fetch before it starts. One thing here is
simply wrong, three requirements are missing, and two of the costs turn
out to be cheaper than the sketch assumed.

### WRONG: there is no such thing as "QUIT with a pathname"

Step 3 above says "issue MLI QUIT with the program's pathname the way a
selector does". No such call exists. The TRM gives QUIT's parameter list
in full, and every field is reserved:

```
PARMTABLE  DFB  4        ;number of parameters
           DFB  0        ;0 is the only quit type
           DW   0000     ;reserved for future use
           DFB  0        ;reserved for future use
           DW   0000     ;reserved for future use
```

"It must consist of seven bytes: `$04` followed by six nulls." A bare
QUIT does not launch anything; it hands control to whatever occupies
`$D100`, and Apple's own dispatcher then PROMPTS the user for a
pathname. Corroborated from the other side by ProSel's disassembly
(`learning:01M0W66B2JBG8DM4Z44N1SD8S4`): a ProSel utility with a
successor name loads it and `JMP $2000` itself, and only "with no name
issues MLI QUIT ($65) and lands back in ProSel".

**So the launch is `bye`'s own work, not the MLI's.** The TRM lists
exactly what a replacement must do, and it is the whole contract:

> To install your own QUIT code that loads your own selector program,
> you must, at some point, store the system program name at $280, close
> open files, clear the bit map, and protect the zero, stack, text, and
> ProDOS global pages, as described above.

That is five duties -- name at `$280` length-prefixed, close, clear the
bitmap, protect four pages, then read the `.SYSTEM` at `$2000` and
`JMP $2000`. Three of them maux already does elsewhere: `SYS_HALT`
(`PRC_HALT`) closes every open file with one MLI CLOSE of refnum 0, and
`src/kernel/procmli.s` already owns the global page. The novel work is
the bitmap and the load.

The good news in this correction: **a bare QUIT is exactly the RETURN
path and nothing else.** The launched program's own QUIT needs no
cooperation from it, which is what makes the round trip free.

### MISSING: `$D100` must be `CLD`

> In addition, the $D100 byte must be a CLD ($D8) instruction, so that
> programs can tell whether selector code or the ProDOS dispatcher code
> is resident.

A one-byte published ABI. maux's resident opens with `CLD` or it lies to
every program that checks.

### MISSING: the startup-pathname protocol

There is a defined way for a selector to hand a pathname to the program
it launches, and it is the only one. The selector inspects the loaded
interpreter at `$2000`: if byte `$2000` is `JMP` (`$4C`) and both
`$2003` and `$2004` are `$EE`, then `$2005` is a buffer size and
`$2006` holds a length-prefixed pathname the selector may overwrite.

Two consequences. `bye PROG STARTUP` can only pass `STARTUP` to a
program that advertises those two `$EE` bytes, so its manual page must
say so rather than implying general argument passing. And the mirror
image is worth taking: if maux's own `.SYSTEM` advertised `$EE $EE`,
any selector -- ProSel, Bird's Better Bye, Apple's own dispatcher --
could boot maux straight into a named program. That is a separate, very
cheap item.

### THE REAL HAZARD: a normal program destroys the resident

`$D100-$D3FF` is in language-card bank 2, and bank 2 is FREE MEMORY as
far as a ProDOS program is concerned. This project already has the
worked example in the commons: EDASM runs its editor's first 4 KB inside
that bank, and saves the bank to `EDASM.SWAP` first precisely because it
knows it is about to destroy the ProDOS QUIT code
(`learning:01M1X0F064TX9PZD2JFVEX9MJJ`). A program that does that and
does not put it back leaves ProDOS copying garbage to `$1000` and
jumping into it. maux is then gone, with no code running that could
notice.

Note the naming trap on the way in. `inc/mm.hw.equ` calls `$C083`
`LCBANK1_RAM` and `$C08B` `LCBANK2_RAM`, which is the OPPOSITE of
Apple's numbering: `$C083` has A3 clear and selects Apple's bank 2, the
one holding the dispatcher, and the file's own `RDLCBNK2` comment two
screens up says so ("bit 7 = the `$C080-$C087` group (`$C083`) is
selected"). So the resident goes in what this tree spells
`LCBANK1_RAM`. The ratchet in [LANGUAGE-CARD.md](LANGUAGE-CARD.md)
already permits it -- the two allowed addresses turn out to be exactly
{ProDOS's MLI bank, the dispatcher bank}, so `bye` needs no exemption --
but the names will mislead whoever writes it.

**The mitigation is better than defending the resident, and it is
cheap.** The save image lives in a RamWorks bank ProDOS cannot see, so
losing the resident loses only the RETURN, never the state. Give the
save bank a header and a checksum, and have `init` look for a valid one
at boot. Then a program that eats bank 2 costs a reboot instead of a
session, and the guarantee `bye` offers becomes "your processes survive
anything the tenant does, including crashing it" -- which is stronger
than what the sketch promised and does not depend on the tenant behaving.

### CHEAPER THAN THE SKETCH SAYS: the /RAM dance is half written

`PRC_RAMDIS` in `src/kernel/procmli.s` already disconnects /RAM at
`PRC_INIT`, and it already saves precisely what a reconnect needs:
`K_HAD_RAM`, `K_RAM_DEV` and `K_RAM_VEC`, with a comment that says "a
future QUIT path reinstalls ... ONLY if it is set". Slice 2's /RAM work
is the mirror of a routine that exists, against state that is already
being kept.

### ONE COST UNDERSTATED: the save bank must be RESERVED, not allocated

"One fewer process slot while `bye` is out" is right about the price and
wrong about the mechanism. `PRC_ALLC_BANK` has three ways to hand out a
bank, and the third (`LZ_RECLAIM`) takes the least-recently-retained
TAGGED bank under memory pressure. A save bank obtained the ordinary way
can therefore be taken back while `bye` is out, silently, by a spawn
that happens to need it. It must be pulled off `PRC_FREE_LIST` and never
tagged, so neither path can see it.

## 2026-09-24 RULING: the tenant is a project you just built

Operator: "scope to projects, not to can we spawn appleworks, publish-it,
etc. they can be spawned on their own merits not as subs".

**The design target is a `.SYSTEM` file assembled, linked and staged under
maux minutes earlier.** Small, ProDOS 8, loads at `$2000`, written by the
person at the keyboard. Commercial applications are a thing you may
choose to launch; they are not a requirement and they do not get a vote
in the design. That is the difference between a dev tool and a program
selector, and this is the dev tool.

### What leaves the design

* **The `$EE $EE` startup-pathname protocol.** It exists so a selector
  can tell BASIC.SYSTEM which program to run. Your own freshly built
  binary needs nothing handed to it by a selector, and if it ever does,
  you control both ends and can pick a better channel.
* **`-k` (kill every process first).** It was there for the tenant that
  walks all the banks. Not a slice-1 or slice-2 concern any more.
* **The RamWorks-aware tenant as a CONSTRAINT.** AppleWorks with an AE
  expander still eats the save bank; that is now a case to DETECT and
  report, not a case to design around.

### What the scoping does NOT weaken -- it strengthens

The argument for checksumming the save bank and having `init` find it at
boot was "a badly behaved application might destroy the resident". Scoped
to your own work that argument gets stronger, not weaker: **the program
under test is one you wrote, have never run, and are launching precisely
because you do not yet know whether it works.** A first run that trashes
language-card bank 2 is not an exotic failure here; it is Tuesday. The
recovery path is what makes `bye` usable on code that does not work yet,
which is the only kind of code anyone points this at.

`$C073 := 0` before handover is unchanged and unconditional. Your own
program's 80-column output lands in an invisible bank just as surely as
AppleWorks's would.

### And it makes the EXIT STATUS achievable, which it otherwise is not

The top of this note requires that `bye` "hand the program's outcome back
to the calling shell as an exit status, so a script can branch on it",
because the target user ends `make test` with a `bye`. There is a problem
with that which the note never states: **ProDOS has no exit status.** A
program QUITs, and QUIT carries nothing -- its parameter list is `$04`
plus six nulls, all reserved (`learning:01M34A439TDASMVQNDCX41QGMN`).
Nothing in the mechanism can tell a successful run from a failed one.

Unscoped, that is unsolvable. Scoped, it is a convention: a program built
under maux can be given a way to leave a status byte where the resident
will find it, because we ship the runtime it is linked against. The
resident reads it on the way back in, and reports "no status" for a
tenant that did not leave one -- which is the honest answer for anything
not built here. The convention needs designing; the point is only that
scoping is what turns it from impossible into a decision.

## 2026-09-26: step 3's /RAM reconnect is WRONG, and the reason generalises

Operator: "the presence/absence of /RAM is a protocol informing ProDOS
programs of whether to consider Auxiliary memory free".

Step 3 above says "Reconnect /RAM (TN #26), then issue MLI QUIT". That
inverts the technote it cites, and it would have destroyed the machine
on the first real tenant.

### The protocol

`learning:01KW1GTYH4NRG0F8M7AAT6EG9Z` quotes TN #26's Rule of Auxiliary
Memory directly: do not reinstall /RAM at quit if it was ABSENT at
launch, because **"its absence means other system software owns aux"**.

So /RAM is not merely a RAM disk. **Its presence or absence is a
one-bit claim on the whole auxiliary bank**, and every well-behaved
ProDOS program reads it that way. Connected: aux is storage, help
yourself. Absent: somebody is already living there, keep off.

### Why reconnecting would be a lie

TN #26's reinstall rule is written for a program that is LEAVING -- it
borrowed aux, it is done, it hands the machine back the way it found
it. `bye` is not leaving. It is SUSPENDING, and every one of its
processes is still sitting in aux, live, waiting to be resumed.

Reconnect /RAM and maux announces "aux is free" while aux holds the
entire process table and every process image. /RAM installs over aux
`$0200-$BFFF` on bank 0 -- which is maux's ANNEX, the bank
`SCH_DISPATCH` selects before every `PCB_RD_FIELDS`. The first write
the tenant makes to its new RAM disk lands on the process table.

**Leaving it disconnected is not a gap in the /RAM dance. It IS the
dance, correctly performed.** The state maux is in -- /RAM absent,
because `PRC_RAMDIS` removed it at `PRC_INIT` -- already says the true
thing to any tenant that asks.

### What this dissolves

A previous note here posed slice 2 as a fork: either save the annex too
(another bank's worth of copying), or leave the tenant without a RAM
disk on a 128K machine. **There is no fork.** The annex never needs
saving because it is never made visible; the tenant is not "missing" a
RAM disk, it is being correctly told that aux is spoken for.

`K_HAD_RAM`/`K_RAM_DEV`/`K_RAM_VEC` are still worth keeping, and
`PRC_RAMDIS` still records them -- but for the FINAL handover, where
maux really is leaving (a `bye` with no return, or `shutdown` giving
the machine back for good). That is the case TN #26 was written for.
Suspend and quit are different verbs and this note had them fused.

### Slice 1's status, unchanged

Slice 1 touches none of this -- grep `procbye.s` and `byeres.s` and
there is no /RAM, `DEVLST` or `DEVCNT` anywhere in them. That was
recorded as "the /RAM dance is out of scope". It is better than that:
for a suspend, doing nothing is the correct behaviour, and slice 2
inherits it rather than having to add the step this note asked for.

## 2026-09-26, OPERATOR RULING: save aux bank 0 and reconnect /RAM

Operator: "it needs to be able to save aux bank 0 to another bank and
reconnect /RAM".

**This reverses the section immediately above, and the section above
was wrong.** Its "suspend is not quit" distinction was mine, and it was
a way of not doing the annex save dressed as protocol. From the
tenant's side `bye` IS a quit: the tenant gets a machine that looks
freshly booted and does not know maux is coming back. TN #26 then says
what to do in plain terms -- reinstall /RAM at quit if it was present
at launch -- and `K_HAD_RAM` records that it was. A 128K machine with
no /RAM is not the standard environment a tenant is owed. The annex is
maux's problem to keep safe, not the tenant's problem to avoid.

Kept above rather than deleted so the next reader sees the wrong turn
and why it was taken.

### The work

1. **A second save bank** for aux bank 0 (`$0200-$BFFF`, the annex:
   PCB table and everything else `SCH_DISPATCH` reads with `BANKSEL`
   at 0). Bank-to-bank `BankCopy` through the bounce buffer. Held
   untagged like `K_BYE_BANK`, and stamped the same way so a
   repossessed bank is detected. **Verify, do not assume, whether the
   kernel ever uses bank 0's `$0000-$01FF` or its language card** --
   if it does, those need the same aux-ZP-gap treatment page 1 got.
2. **Reconnect /RAM before the QUIT.** The exact inverse of
   `PRC_RAMDIS` (`src/kernel/procmli.s`): `K_RAM_DEV` back into
   `DEVLST`, `K_RAM_VEC` back into `$BF26`, `DEVCNT` incremented. The
   state was saved for precisely this and read by nothing until now.
3. **Give the tenant a VOLUME, not the annex's bytes.** Bank 0 has not
   held a ProDOS volume since `PRC_RAMDIS` ran at boot, so reconnecting
   the driver alone hands the tenant unreadable blocks. A fresh boot
   formats /RAM; `bye` must too. **Open question the commons did not
   settle (searched 2026-09-26): whether ProDOS's own /RAM driver
   implements the FORMAT command (`$03`) through its vector.** If it
   does, call it. If not, write a minimal empty volume -- boot blocks,
   a volume directory, a bitmap -- and prove it with an MLI `ON_LINE`
   for unit `$B0` and an OPEN of `/RAM` from the leave side.
4. **On the way back, in this order:** disconnect /RAM again (the
   `PRC_RAMDIS` sequence, TN #8's `ON_LINE` to erase the stale VCB
   included) **BEFORE the tick is re-armed** -- a tick taken while
   /RAM's driver has RAMRD on aux is the BRK-grinder wedge
   `learning:01M1B7W9Z76TMAKP7YPG63F7WQ` records; then restore the
   annex from the second bank; then the existing main restore.
   Whatever the tenant wrote to /RAM is discarded, deliberately.

### The gate

A round trip that has /RAM reconnected AND WRITTEN TO in the window --
a file created on `/RAM` from the leave side before the QUIT trigger
-- and on return: `DEVLST` shows no /RAM, the annex is byte-identical
(a PCB-table checksum before and after), every process resumes, and
the second bank's stamp verifies. Teeth: skip the annex restore and
the checksum must go red; skip the re-disconnect and the tick re-arm
must wedge, exactly as the commons says.

### Cost, stated before it is measured

Two banks held while `bye` is out, roughly double the copy time, and
more `procbye.s` bytes against `MAUXPLAY.SYSTEM`'s **284 B** of
headroom. That headroom may not survive this; if it does not, the
answer is to move code into the disk-loaded resident or the `bye`
program, not to raise a ceiling.

### 2026-09-26: IMPLEMENTED -- 77 B headroom remaining, FORMAT moved
### to byeres.s after the driver-call recipe measured a hang

Built as specified, with one load-bearing correction found by
building it, not by reading further: **step 3's own "JSR the device
driver address" FORMAT recipe reliably hangs the round trip.** The
TRM's own recipe is followed to the letter (`$42-$47` contract,
`$42=3`, Apple LC bank 1 on) and the driver's own internal work
leaves RAMRD/RAMWRT pointed at aux; the `jsr`'s return address lands
back in ordinary `$0200-$BFFF` kernel code, RAMRD-governed for
fetch, and the next instruction misfires into the just-formatted
(mostly zero) annex -- measured directly on the parked emulator
(`PC` in the $2000s, disassembling as `BRK`, `RAMRD=aux`,
`RAMWRT=aux`). The fix writes the volume DIRECTLY, from `BYE_LEAVE`
(byeres.s, LC-resident, already tolerant of RAMRD/RAMWRT flips),
against a layout cross-checked with `~/src/a2til`'s own
`prodos.py`. Full trail, both sabotage transcripts (the annex-restore
skip wedges main via a corrupted PCB table; the redisconnect skip
wedges the tick exactly as `learning:01M1B7W9Z76TMAKP7YPG63F7WQ`
predicts, reproduced with `ls /nope` per that learning's own
recipe), and the size accounting are in
`docs/BYE-SLICE1-NOTES.md`. `MAUXPLAY.SYSTEM`: 30412 B -> 30619 B
(+207 B), 77 B of `PT_HOLD` headroom remaining. Gate:
`scripts/check_rambye.py` / `make check-rambye`.

## Slice 2 launch: `bye PATH.SYSTEM` -- a real tenant, 2026-09-26

Operator: "what's e2e running in prodos space?" -- nothing, until this.
No independent program has ever seen the handed-over machine. This
slice launches one and proves it ran on a standard ProDOS.

### The contract, from the commons (`learning:01M34A439TDASMVQNDCX41QGMN`)

QUIT carries no pathname. The launch is `bye`'s own work, and the TRM
lists it: pathname at `$280` length-prefixed; close open files; clear
the bit map leaving pages `0`, `1`, `4`-`7` and `$BF` marked used (zero
page, stack, text, global page); read the `.SYSTEM` flat at `$2000`;
`JMP $2000`. `$D100` is already `CLD`.

### What changes

1. **`bye PATH.SYSTEM` takes an operand.** Bare `bye` keeps slice 1's
   round trip with no tenant, so every existing gate stays valid. A
   path that is not a `.SYSTEM` file (ProDOS type `$FF`) is refused
   with a message -- gate the form a human types.
2. **Park every open file before the save.** The tenant needs a clean
   ProDOS open-file table. A `PRC_PARK_ONE` loop until nothing
   parkable remains. **A PINNED entry (relatively-opened,
   `PRC_OFT_SETP`) cannot be parked; refuse the `bye` and name the
   fd.** Do not invent a canonicalise-at-bye policy in this slice --
   record it as the trigger for one.
3. **The launch runs from LC-resident code, after the save and the
   /RAM reinstall.** Poison stays. Then: `$280`; ProDOS-level
   `CLOSE` of refnum 0 for belt and braces; bitmap; prefix set to the
   tenant's directory; OPEN/READ/CLOSE the tenant into `$2000`; the
   glass (below); `cli` -- a fresh ProDOS runs with interrupts
   enabled and nothing is armed, so this is the standard state; `JMP
   $2000`.
4. **Size limit, stated not discovered.** The read lands in main
   `$2000` up to `PMLI_IBF_BASE` (`$9800` then, `$A000` since B1),
   and the MLI's own io_buffer for the tenant file sits above that.
   A tenant longer than `$7800` bytes would overrun the buffer it is
   being read through; B1 kept `$7800` as policy rather than let the
   accepted size grow with the pool. Refuse it with a message; the proshim's read-high-and-
   copy-down (`learning:01M1X4K315A16D5ZGCYD54R5VV`) is the upgrade
   path, not this slice's.
5. **The glass, minimum standard.** Text mode, page 1, 40 columns,
   80STORE off; if the UltraTerm owns the display, hand it back to
   the motherboard. The tenant proves it by printing through ROM
   `COUT` and the harness reading the 40-column text page. Nothing
   fancier this slice.
6. **Where the bytes go.** SETTLED 2026-09-27, docs/KSEG.md: the escape
   hatch this item asked to "say which" of IS the kernel cold segment
   -- LC bank 2 at `$D400-$DFFF`, 3 KB, reloaded from `/BASIC/KSEG` on
   every boot and after every tenant return, via `KSEG_LOAD` (the SAME
   routine `PBY_LOAD_RES` now calls, generalized rather than staying
   a second bespoke loader). `PRC_BYE`, `PRC_RAMRECONN`, and
   `PRC_RAMREDISC` all live there now (`src/kernel/kbye.s`), moved out
   of the flat `procbye.s`/`procfile3.s` this item was measuring
   headroom against -- the 77 B/336 B figures above are historical
   (procbye.s's own remaining flat routines are a thin trampoline plus
   the ALTZP-bracketed helpers docs/KSEG.md rule 1 forbids moving:
   `PBY_PATCHFRM`, `PBY_CHK_STAMP`, `PBY_WR_STAMP`, `PBY_WR_P1`). See
   docs/KSEG.md for the segment's own rules and `]KSEG_WANT` scoping
   (currently MAUXPLAY only; docs/DEV-BLOCK.md records the trigger
   for widening it).

### The tenant

`src/test/byetenant.s`, a real `.SYSTEM` (`org $2000`, type `$FF`),
staged on `play.po`. On entry: `ldx #$FF / txs`; read `$280` and
verify it names this program; CREATE and WRITE one byte to
`/BASIC/BYE.MARK` and one to `/RAM/RAM.MARK`; print `TENANT RAN` via
`$FDED`; MLI QUIT. Small enough to read in one sitting, because it is
also the worked example of what a tenant is owed.

### The gate

`bye /BASIC/BYETENANT.SYSTEM`, then: `TENANT RAN` appears on the
40-column text page WHILE the tenant runs (poll during the window,
not after -- afterwards the restore has repainted it); "Welcome back."
and a prompt; `/BASIC/BYE.MARK` exists with the byte (the program ran,
on a standard machine, through real ProDOS); `/RAM/RAM.MARK` is GONE
and `DEVLST` shows no /RAM; the annex verifies against its snapshot;
the post-return exercise passes. Teeth: skip the `JMP $2000` and there
is no `TENANT RAN` and no marker -- the launch is the sabotage; the
existing annex-restore and redisconnect sabotages still bite.

### Still not this slice

The exit status. ProDOS has none; the convention is the last named
gap. Pinned-file canonicalisation, and the read-high loader, are
triggers recorded above.

## 2026-09-27: the launch landed, and three lines of this spec were wrong

Merge `43e250a`, box sweep 114/0 on the branch. A real `.SYSTEM` runs
on the handed-over machine, writes files through real ProDOS, prints
through the ROM, QUITs, and maux comes back with a legible console.
Gate `check-tenant`; its sabotage is the launch itself. The gate took five debugging rounds to turn green.

**Corrections to the section above, each measured:**

1. **"Poison stays" is wrong for a launch.** The poison covers
   `$0478-$07FF`, the screen holes where every slot ROM keeps per-slot
   scratch. The SmartPort WRITE path consults that state; the tenant's
   first CREATE spun forever in real driver code. On a launch the
   tenant IS the destruction and the poison is skipped; bare `bye`
   keeps it so slice 1's witnesses keep their teeth. Firmware scratch
   is part of "a standard machine".
2. **The tenant needs the ROM readable, and the spec did not say so.**
   [LANGUAGE-CARD.md](LANGUAGE-CARD.md)'s ratchet permits only read-RAM
   selects, so a tenant inherits LC RAM at `$D000-$FFFF`; MLI calls
   work because the MLI reselects its own bank, and the first ROM
   `COUT` hits a BRK in ProDOS's bytes at `$FDF7`. The launch selects
   read-ROM (`$C082`) as its last act, **from a page-1 stub** -- the
   select unmaps the LC code issuing it for the very next fetch, the
   same class as ALTZP -- exactly as Apple's own QUIT dispatcher does,
   under the `check_lc` exemption `proshim` already carries. This is
   the window `shutdown -r` was told to wait for.
3. **CLOSE(refnum 0) runs BEFORE the poison, in kernel context.** After
   it, ProDOS reads poisoned FCB bytes as open files.
4. **The glass must be put back by the console, not by a list.**
   Dropping `COL80`/VIDSEL for the tenant and restoring only 80STORE
   on return gave every-other-character text -- the signature
   seen earlier for `shutdown`. Resume now runs
   `TTY_HW_SET`, the routine `chvt` and `vidmode` already use.

**The constraint that replaces the byte budget:** `MAUXPLAY.SYSTEM`
ends at exactly `$97E8`, zero bytes below the harness cells, after
four fixes each paid for by scraping `stz`s out of unrelated routines.
The next byte anywhere in the put chain needs the kernel cold segment
in language-card bank 2 ([DEV-BLOCK.md](DEV-BLOCK.md) hit the same
wall from the other side, +1096 B). `check_pt_hold_headroom()`'s code
is `end > low` where its docstring says "below"; not tightened.

Named, not built: the exit-status convention; dualhead VIDSEL not
restored (`vidmode hq` recovers it); pinned-file canonicalisation at
`bye` time; the read-high loader for tenants over `$7800`.
