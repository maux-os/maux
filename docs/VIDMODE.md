# Multi-mode consoles: the considered design (2026-08-31)

Status: LIVE. `vidmode` (`src/bin/vidmode.s`, `docs/man/vidmode.1`) and
the per-console surfaces shipped: V1.1-V1.5 landed 2026-09-01 and V2.0
(the card as a per-console surface) 2026-09-03; see the LANDED
sections below. The text before them is the design as considered.

Operator rulings this document serves: *"consoles [are] multi-mode
-- console 1 displaying ultraterm while console 2 has a BASIC
program in 40 col; stock 80 col needs to be an option"* (sec 14,
2026-08-30) and *"not cheap, I want a considered approach which
delivers the dwim solution"* (2026-08-31). DWIM here means: a
human says what shape they want a console to be, in the form a
human types, and it happens -- validated against real hardware,
correct across switches, redirects, the editor and the stores,
with errors spoken rather than wedged.

## 0. The primary source is now settled

Sec 14's mode table was `[observed]` off poor OCR. The Videx Quick
Reference Guide and the manual's Appendix C have now been read
VISUALLY (learning:01M0J3M2B5DJJ4A3YVX7RNFK6N, upgraded, QRG
attached). Facts that change the design:

- **NINE video formats, the card's own numbering 0-8**: 0 = Apple
  40-col pass-through; 1 = 80x24; 2 = 96x24; 3 = 160x24;
  4 = 80x24 HQ charset (interlace); 5 = 80x32 (interlace);
  6 = 80x48 (interlace); 7 = 132x24 (interlace); 8 = 128x32
  (interlace). The OCR's list missed 80x32 and 128x32. Still no
  96x48.
- **CRTC model** ($C0B0 select / $C0B1 data, 18 registers): R1 =
  displayed columns, R6 = displayed rows, R9 = scanlines/cell - 1,
  R12/13 = start address (the scroll ring), R8 bits 0-1 =
  interlace (11 = sync+video, the 32/48-row modes, and Videx says
  plainly a long-persistence phosphor is required).
- **Per-mode R0-R9 value sets for formats 2-8 are NOT yet
  extracted** -- they live in the manual's own Appendix F firmware
  listing (the VIDEO FORMAT handler's tables). Named step V2.1.
- 128x32 = 4,096 cells = the 4 KB VRAM ring exactly.

## 1. The mode model

A console's mode is `(backend, cols, rows, discipline)` -- the
fourth axis by operator ruling, 2026-08-31: *"multimode has to
encompass apple style vs vt style console behaviour."* Geometry
says how many cells; **discipline says what the byte stream
MEANS**, and the sec-14 use case was always both: a BASIC program
on console 2 needs 40 columns AND Apple semantics.

| backend | geometries | hardware needed |
|---|---|---|
| `TTY_BK40` | 40x24 | always present |
| `TTY_BKN8` | 80x24 | any //e with aux (always, here) |
| `TTY_BKUT` | formats 1-8 above | UltraTerm answering slot 3 |

Three cells move INSIDE the `VC_STATE`..`VC_ST_END` block:
`TTY_BKND`, `TTY_COLS`, and new `TTY_ROWS` (rows stop being a
constant the day 80x32 exists; until V2 lands its value is always
24, but the clears, scrolls, CSI clamps and blits convert to it in
V1 so the geometry generalization is proven while it is cheap to
test). `VC_SWITCH`'s save/load then carries mode per console with
no read-site changes -- sec 14's "structural half". Every console
cold-starts in the BOOT mode (the existing `TTY_BKND_REQ` probe is
unchanged), so a machine that boots 40-col feels identical until
someone asks for more. DWIM: inherit, don't surprise.

## 1b. The discipline axis: Apple style vs VT style

`TTY_DISC` per console (in `VC_STATE`): `DISC_VT` (today's
behavior, the only one that exists) and `DISC_AP`.

**Discipline is orthogonal to geometry and backend** (operator,
2026-09-01: "the 80 mode needs to be switchable between apple and
vt"). Every combination is legal: `vidmode 40 apple` is the BASIC
console; `vidmode 80 apple` is the PR#3 world -- Apple-native
software at 80 columns, the built-in firmware's own precedent;
`vidmode 80 vt` is a Unix console at 80. Nothing in the dispatch
may couple DISC_AP to a width.

**Output.** `TTY_PUT_BYTE` dispatches on the discipline before
anything else:

- `DISC_VT`: the current parser -- CSI machine, VT subset, ESC [
  everything. What Unix programs speak.
- `DISC_AP`: the Apple 80-column firmware's control-character set
  -- the language every Apple-native program already speaks at its
  COUT: Ctrl-K clear-to-end-of-screen, Ctrl-L form-feed =
  home-and-clear, Ctrl-N/Ctrl-O normal/inverse, Ctrl-V/Ctrl-W
  scroll, Ctrl-Y home, Ctrl-Z clear-line, Ctrl-]
  clear-to-end-of-line, Ctrl-_ up, and the rest of **Table 3-3b**
  (Apple IIe Technical Reference 1987, p.53 -- located this
  session; the exact table is extracted VISUALLY at
  implementation, the CRTC-table pattern, with the IIc TR's
  equivalent appendix as cross-check). ESC is NOT a sequence
  introducer here -- a stray ESC in Apple output is not the start
  of anything. High-bit control bytes ($8D et al., how Apple
  programs actually emit) land identically -- the parser's #$7F
  fold already guarantees it. Explicitly OUT of the first cut:
  MouseText mapping and the Pascal 1.1 video protocol (its
  CHR$(30) GOTOXY family is a THIRD dialect, manual p.263) --
  both named, neither blocking.

**Input.** The discipline gates everything the VT side added:

- `DISC_VT`: arrows synthesized to CSI, OA-as-Meta ESC prefixing,
  the readline editor, history -- as landed.
- `DISC_AP`: keys pass RAW -- arrows as their native $88/$8A/$8B/
  $95, ESC as ESC (the APPLICATION does Apple escape-editing,
  Table 3-6 -- that is where it has always lived), no CSI
  synthesis, no readline dispatch, no OA prefixing (OA stays a
  readable button, as Apple software expects). Cooked mode
  degrades to the pre-readline minimum: BS erase, CR commit.
  KEYIN's translation layer and the cook's binding dispatch each
  test `TTY_DISC` once.

**Not discipline-dependent, on purpose**: ^C (kernel semantics,
not terminal style -- an Apple-style console still belongs to a
Unix kernel), the reserved row 0, chvt via its CSI... which on an
Apple console cannot arrive by output escape, and does not need
to: chvt is a maux COMMAND -- its write happens on whatever console
sh runs on, and a keyboard-side switch gesture (OA+n, post-#16) is
discipline-free. The BASIC-as-a-process milestone (CONSOLE.md sec
9) sets its console's discipline at spawn or by the escape below
-- its choice, both work.

**Gating**: an APPLE control-code battery in playtestb mirroring
the VT battery, with Table 3-3b as the oracle; a discipline-switch
phase; and negative legs on both sides -- ESC f on an Apple
console must NOT word-jump, Ctrl-L on a VT console must NOT
home-and-clear (it redraws, as gated today).

## 2. The verb, and the wire

**The wire is a private CSI, geometry-addressed:**
`ESC [ <cols> ; <rows> ; <disc> v` -- sibling of chvt's
`ESC [ n z`, same rationale (no ioctl; any process that can write
its tty can ask; GNO's ioctl remains the recorded long-term home).
Geometry, not backend, on the wire: the kernel derives the
backend, so the escape stays stable if backends multiply. The
third parameter is the discipline (0/absent = keep, 1 = vt,
2 = apple); cols=0 keeps geometry, so `ESC [ 0 ; 0 ; 2 v` is a
pure style switch. The escape is honoured from EITHER discipline's
parser -- it is the one CSI the Apple-side parser recognizes,
because a console must be able to switch back (precedent: the
real 80-col firmware also kept exactly one escape-shaped door,
Escape-Ctrl-Q). Derivation rule:
40x24 -> BK40; 80x24 -> **N8** (the motherboard wins ties -- zero
hardware risk; the UltraTerm's 80x24 is reachable as the HQ
format once V3 lands); anything else -> UT, validated.

**Validation is kernel-side and silent-on-the-wire** (terminal
discipline: an impossible escape is ignored, like ESC [ 9 z
today), so the SPEAKING is the utility's job:

**`vidmode`** (src/bin): `vidmode 40`, `vidmode 80`,
`vidmode 132` (unique -> 132x24), `vidmode 80x48`,
`vidmode apple` / `vidmode vt` (pure style switch),
`vidmode 40 apple` (both at once -- the BASIC console in one
breath), `vidmode` alone prints the current mode, `vidmode list`
prints what THIS machine can do. It writes the escape, then READS BACK the
geometry and says so -- `vidmode: 132x24` on success,
`vidmode: no ultraterm card` when the switch didn't take. The
read-back needs:

**A geometry query** -- `SYS_TTYGEO` (or an FDSTAT extension,
implementer's choice): returns (cols, rows, backend) for a tty
fd. Wanted independently by any full-screen program ever written
for maux (the TIOCGWINSZ ancestor); vidmode is merely its first
caller. This is the piece that makes the whole feature honest --
without it every consumer guesses.

## 3. The stores: geometry costs an address, and the map moves

Worst-case store is 4,096 cells (128x32). Four consoles at worst
= 16,384 B; ANNEX_STRCT_C cannot hold that beside the cwd table,
LZ tags, VC slots and history (26,154 > 24,576). The map's own
text names the answer: ANNEX_STRCT_B / the DHR page companions
($2000-$5FFF) are "HARD video reserve / **temporary text-only V1
reclaim**". The stores claim $2000-$5FFF -- 4 fixed 4,096-byte
slots, no allocator cleverness -- and the claim is a named debt:
**the graphics future evicts the stores** (back to variable-size
slots in STRCT_C, or smaller history, whichever the day prefers).
STRCT_C's current tenants do not move. Store rows are laid out
linearly at the console's OWN stride; the fixed VCS_RLO/RHI
80-stride tables become per-console row tables regenerated into
the store slot's header on every mode set (48 rows x 2 bytes = 96
B, computed once per vidmode, never per character).

**And when the graphics future arrives, it is a MOTHERBOARD
future** (operator, 2026-09-01; deposited as
`learning:01M1DCN57SQE9RRYFR5HV10XN0`): mixed-mode graphics with
an 80-column text window is a builtin-only trick -- the IOU
serves both from the same aux-memory scanner, while an external
card (UltraTerm) REPLACES the whole picture via ENVID' and
composites with nothing. That asymmetry is reportedly what ended
the third-party 80-column card market, and it shapes this design
twice over: a graphics+text tuple is never servable by the UT
backend (the geometry-addressed wire stays honest for free), and
on a UT-boot machine a future mixed mode needs the VIDSEL
pass-through -- the glass itself must come back to the
motherboard, not merely the card reprogrammed. The hardware
floor for that future is Revision B+: the Rev A //e's timing
HAL has no AN3 input, so the BUILTIN video cannot make
double-res timing there (`learning:01M1DCTH5DCEB96YBF1JDR5K44`;
a card that generates its own video, like an RGB adapter,
escapes the HAL -- but RamWorks carries no video generator) -- a
floor maux already stands on by accident, since an unmodified
RamWorks will not run in a Rev A machine at all. And when that
mixed mode comes, its text window follows 80COL: under DOUBLE
hi-res it is 80-column BY SILICON -- DHR requires 80COL, and
there is no 40-col text under it (AIIe TN #3, now attached to
`learning:01M1DDA0X6MEQ031BD9SABBGD0`: paint only the main half
and every second window character is aux-page garbage) -- while
SINGLE hi-res mixed takes either width (HIRES40 + TEXT40 is the
machine's oldest normal case). So the DISC_AP 40-column console
can share a screen with single-hires graphics but never with
DHR, and the mixed window's console plane must be an 80-wide
store from day one -- which the fixed VC_STR_COLS=80 stride
already is.

## 4. UltraTerm consoles write THROUGH, and that fixes an old gap

The card's VRAM is write-only over the bus, which is why today's
VC_SWITCH "leaves the image stale" -- switching away from the
UltraTerm and back LOSES the screen. Under multi-mode that is not
a corner, it is the main path. So a UT-backend console's cell
writes go to VRAM **and** to its store (the TTY_STORE_Y bracket
generalized; ~20 cycles/char, UT consoles only), switch-out saves
nothing, and switch-in repaints VRAM from the store -- the same
store-is-truth shape the 40-col redirect already proved. The
stale-image gap dies as a side effect.

## 5. VC_SWITCH programs hardware, not just state

Switch-in, when backend or geometry differs from the outgoing:
- BK40: COL80OFF (+ the existing soft-switch hygiene).
- BKN8: N8_INIT's switches (COL80ON, 80STORE discipline).
- BKUT: the $C0B2 latch (VIDSEL/VTEMU/page), CRTC R0-R9 from the
  per-format table, charset selection -- then repaint from store.
The blit generalizes to the console's stride/rows. The reprogram
happens OUTSIDE the sei'd struct exchange, like the blits today
(a mid-switch tick cooks into a buffer, not the glass).

## 6. Ripples audited against today's tree

- **Redirected writes to a background console of a different
  shape**: free by construction -- TTY_WR_ENTER swaps the whole
  struct, so TTY_COLS/ROWS/BKND are the TARGET's; the store write
  uses the target's stride tables.
- **The readline editor**: wrap math reads live TTY_COLS; nothing
  else to do.
- **VCS_SCROLL / clears / CSI clamps**: convert #24/#23/#40
  literals to TTY_ROWS/TTY_COLS reads (grep-the-whole-tree sweep;
  the N8 glass clear's 40 stays -- it is the main HALF of an
  80-column screen, already documented as load-bearing).
- **Row 0** stays the global status line in every mode; the body
  is rows 1..TTY_ROWS-1.
- **History, chvt, ^C, /dev routing**: geometry-free already.
- **check-play's fixed-address peeks**: boot mode is unchanged, so
  existing gates stand; new phases type `vidmode` forms.

## 7. Hardware and emulator realities, named before they bite

- **Pre-addendum UltraTerms are interrupt-hostile** on an enhanced
  //e (ULT-DOC-000; sec 14). The SLOTC3ROM-internal mitigation
  rides along with any UT mode work.
- **verilogapple's UltraTerm model must be verified for non-80x24
  CRTC programs before V2 is gated on it** -- if its renderer
  hard-codes the Videoterm-emulation geometry, that is an issue to
  the verilogapple agent FIRST (the #16 lesson: file early, the
  turnaround was same-day). MAME's `ultratermenh` gets the same
  check.
- Interlace modes (V3) additionally want a think about what a
  50/60 Hz emulator frame even shows for sync+video interlace.

## 8. Staging, each stage green before the next

- **V1 -- geometry generalization + 40/N8 per-console + the verb.**
  Cells into the struct; TTY_ROWS conversion sweep; stores to
  $2000 with per-console stride tables; VC_SWITCH reprogramming
  for BK40/BKN8; `ESC [ c ; r v`; SYS_TTYGEO; vidmode; gates:
  console 1 at 80 / console 2 at 40 with redirects and recalls
  crossing them, teeth by sabotage on the reprogram and the
  stride tables.
  **LANDED 2026-09-01** (V1.1-V1.5 + the check-play vidmode
  phase). Two things the design did not call and the first live
  run did: (1) a background console's mode change must not run
  the GLASS-shaped body clear -- N8_CLR_AUX raw-stores through
  store addresses, which in main memory is kernel text at $2000+;
  the redirect branch clears via VCS_CLR_BODY and touches no
  hardware. (2) Row 0, the reserved status line, is in no
  console's store, so every 40<->80 transition re-lays it
  (TTY_ST_RFLW), from both TTY_CSI_MODE and VC_SWITCH
  (VC_OLDBK/VC_RFLW_CK). The wire grew a third parameter for the
  discipline (`ESC [ c ; r ; d v`, 1=vt 2=apple, 0=keep) so
  vidmode would not need a second escape when D1 lands; the
  kernel stores TTY_DISC today and dispatches on it in D1.
- **D1 -- the discipline axis.** TTY_DISC cell + the two-way
  dispatch in TTY_PUT_BYTE, KEYIN and the cook; the Apple
  BASICOUT control set (D1.1: extract Table 3-3b from the 1987 TR
  scan visually, upgrade the commons); the APPLE battery +
  discipline-switch + negative gates. Sequenced right after V1
  and before any UltraTerm work, because "BASIC in 40 col" is the
  named use case and needs no card.
- **V2 -- UltraTerm native, non-interlace: 96x24, 160x24.**
  V2.1 extract per-format R0-R9 from Appendix F (upgrade the
  learning); V2.2 emulator capability check (verilogapple + MAME);
  V2.3 write-through store + switch-in repaint (kills the stale
  gap); V2.4 modes + gates on check-play80's rig.
- **V3 -- the interlace family** (HQ 80x24, 80x32, 80x48, 132x24,
  128x32) once V2's plumbing is proven; 128x32 documented as
  scroll-poor (the ring is exactly full: scroll = memmove, not
  R12/13 origin walking).

## 9. Three rulings (taken as recommended)

All three recommendations below were adopted: the verb is `vidmode` with
geometry arguments, V1 stores moved to `$2000` with the reclaim, and V1
landed alone first (sec 8).

1. **The verb's spelling** -- `vidmode` with geometry args as
   above, or a different name/shape (`stty`-flavoured? the card's
   own 0-8 format numbers?). Recommendation: `vidmode` + geometry;
   format numbers are UltraTerm trivia, geometry is what a human
   means.
2. **The store relocation** -- DHR companions ($2000-$5FFF) as the
   text-only-V1 reclaim the map already sanctions, vs shrinking
   history/store worst-case to stay inside STRCT_C.
   Recommendation: the reclaim, debt named for the graphics
   future.
3. **Staging consent** -- V1 (40/N8 + verb + query) lands alone
   first, UT follows behind the emulator capability check.
   Recommendation: yes; V1 is where every structural risk lives
   and it is fully gateable on the rigs we have today.

## 10. V2.0 LANDED 2026-09-03: the card is a per-console SURFACE

Operator, 2026-09-03: *"the UltraTerm is not always the best choice ...
as a replacement for Apple's 80 column mode it depends on the
application. ProSEL used to allow an UltraTerm user to configure which
launched app used which mode. We should allow switching between the two,
especially since with the virtual consoles and an UltraTerm card you
actually get multihead support."* This section records what landed for
that, and the three rulings it TOOK AS DEFAULTS rather than waited for --
each is one line to change.

**The wire grew a fourth parameter, the surface:**
`ESC [ <cols> ; <rows> ; <disc> ; <surface> v`, surface 0 = derive
(today's rule: 40 -> BK40, 80 -> BKN8), 1 = motherboard, 2 = the card.
Only 80x24 surface 2 is new: it selects the UltraTerm's existing HQ
80x24 program, accepted only when a card answers (`UT_DETECT` runs at
that moment if boot never probed, i.e. a forced 40/N8 boot). 40 columns
on the card is refused (no such format here). `vidmode hq` / `vidmode
card` speak it; `vidmode 80` on a card console now MEANS the motherboard
and is no longer refused -- the V1 pin is gone. The read-back checks the
backend the kernel reports, so `vidmode: refused` still fires if the
surface did not take. The report says `80X24 HQ VT` on the card.
*Ruling taken:* a fourth parameter rather than a new geometry token,
because the two 80x24s differ in cell height, not geometry, and the wire
was already parameter-shaped. Sec 9 item 1 stands otherwise.

**Surfaces are independent glasses (operator ruling, 2026-09-03 evening).**
The motherboard text page and the card are two glasses, each owned by at
most one console (`VC_OWNER`, tty.s; the helpers in tty8.s). The owner of a
surface writes to its glass even from the background -- so a shell on a card
console keeps painting the card live while a built-in console holds the
keyboard; every other background console writes to its store. A switch onto
a surface blits only when the incoming console is not already its owner.
When the active console LEAVES a surface (`vidmode`), the glass passes to
another realised console of the same backend if one exists (lowest-
numbered), else it is cleared and unowned.

**Whether VIDSEL is held across a switch is the HEAD MODE, and it defaults
to SINGLE monitor (operator ruling, 2026-09-04; supersedes the "VIDSEL is
never cleared" default the first cut took).** The card owns the one soft
switch that routes the monitor (VIDSEL, `$C0B2` bit 6): set, the card
drives it; clear, the motherboard video shows through. With one monitor the
switch must FOLLOW the active console, or `vidmode 80` moves your console to
a motherboard text page the card is hiding and the screen looks broken (it
was: the "never cleared" default made `vidmode 80` show a blank card on both
verilogapple and Virtual ][). So by default `TTY_HW_SET` drops VIDSEL
whenever a motherboard console takes the glass and a card was driving, and
sets it for a card console -- the one screen shows whatever is active.
`vidmode dualhead` opts into HOLDING VIDSEL instead, for a real second
monitor: then the card keeps painting its own console live while a
motherboard console runs on the other head. `vidmode onehead` returns to
the default. See sec 11.

**Boot default is the best surface present (same ruling).** UltraTerm HQ
80x24 if a card answers, [a plain Videx 80-column card would be next -- no
driver and no emulator model exist, so the slot is named in TTY_INIT and
empty], else the built-in 80 columns. 40 is never a default: the system
needs aux memory, so 80 is always there. Test harnesses that assert
40-column screens pin it (`TTY_BKND_REQ=1`; the play image via the `PT_F40`
poke).

**A console does not exist until realised, and it inherits the live
console's mode (same ruling).** `VC_RESET` no longer copies the boot cells;
the console that was live when the new one was first touched -- by `chvt`
or by a write to its `/dev/ttyN` -- is what it looks like. Option plus a
digit as the realise-and-switch gesture stays parked on verilogapple#16
(no gate can hold the button); `chvt` drives it meanwhile.

**UltraTerm consoles READ BACK on switch-away (V2.3, reverses the V2.0
write-through).** The V2.0 ruling below took write-through "because the
card's VRAM cannot be read" -- but that premise was an *emulator* gap,
not hardware: the real card (and MAME) gate the `$CC00` window's reads
on MEMSEL (`$C0B2` bit7), and maux runs MEMSEL clear, so the window
reads VRAM. verilogapple was pinned to MEMSEL on 2026-09-10 (its
`ultraterm_slot.h`; commons `learning:01M06YDGM1Q52V5TXX3GA8A2FZ`, which
had flagged the bit "not yet pinned"). With read-back available, the
card now follows the SAME model as 40-col/N8: the active console writes
the glass (VRAM) only, and `VC_SWITCH` SAVES the outgoing card's VRAM to
its store (`VCS_UTSAVE` -> `UT_GET_ROW`, the read mirror of
`VCS_UTBLIT`) before loading the incoming one. The per-cell store write
(`UT_ST_CELL`), the per-scroll store scroll (`VCS_SCROLL` on the card
path), the body-clear store, and the batch `VCS_ST_SPAN` are all gone;
`UT_SCROLL` is once more JUST the CRTC display-start bump + clear. vi's
alt-screen park (`VCA_MOVE`, tty5.s) snapshots VRAM the same way before
copying store->alt. Measured: `cat` of a 60-line file on the card,
1.20 M cycles (write-through) -> 0.90 M (read-back). Switch-in is
unchanged (`VCS_UTBLIT` -> `UT_PUT_ROW`, repaint from store at the
current `UT_START`). *Ruling taken (V2.3):* read-back-on-switch, now
that the window reads; the V2.0 write-through ruling below is superseded
(its premise is corrected, not merely outweighed).

*(Superseded V2.0 ruling, kept for the record.)* Write-through rather
than read-back-on-switch, because the card's VRAM was believed
unreadable (sec 4's own argument, since corrected).

**Not done here, still V2/V3 as staged in sec 8:** the card's OTHER
formats (96x24, 160x24, the interlace family) -- those need Appendix
F's CRTC tables; D1 (the Apple discipline); the Videoterm backend; the
Option-digit gesture.

Gate: `check-play80` grew a switching phase -- `vidmode 80` moves the
booted card console to the motherboard (prompt on the text page) and the
card RELEASES the monitor (VIDSEL drops, single-head default), `ls` runs
there, `vidmode hq` brings it back (VIDSEL on, report on the card), then a
marker is echoed, `chvt 2` shows a fresh card console without it, and `chvt
1` shows it again -- restored from the store, the only place it could have
come from -- then the dual-head leg: `vidmode dualhead` opts in, console 2
is moved to the built-in surface from the background, made active, and
console 1's `echo` lands on the card live (VIDSEL held) while the
motherboard shows console 2. Teeth: with the write-through disabled the
marker does not come back; without `dualhead`, `chvt 2` would drop VIDSEL
and the card would show nothing during the sleep.

## 11. HEAD MODE: single monitor by default, dual head opt-in

Added 2026-09-04 after the "VIDSEL is never cleared" default (sec 10) made
`vidmode 80` look broken on one monitor -- the console switched, but the
card kept the glass and hid it. The head mode is a single machine-wide
cell, `TTY_DUALHEAD` (ultraterm.s): 0 = single monitor (the default), 1 =
dual head.

- **Single (0):** `TTY_HW_SET` drops VIDSEL when a motherboard console
  (BK40/BKN8) takes the glass and a card was driving (`UT_INITED` set),
  and sets it for a card console. The one monitor follows the active
  console. Nothing to drop on a machine with no card -- `UT_INITED` is 0
  and the branch is a no-op, so 40-col and native-80 machines are
  unaffected.
- **Dual (1):** VIDSEL is held across the switch, so the card keeps
  showing its own console (painted live from the background by its owner)
  while a motherboard console runs on a second monitor. This is the
  multihead the operator asked for -- it just is not the default, because
  most people have one screen.

**Wire:** the head mode rides the mode escape's surface field rather than a
new final byte (a new `ESC [ n w` would have grown tty2.s, the largest
kernel put, past the `as` self-host source window and broken two
zero-headroom test kernels -- check-dialect 3b). So `ESC [ 0;0;0;3 v` =
onehead, `ESC [ 0;0;0;4 v` = dualhead: surface 3/4 is not a surface at all,
it is caught at the top of `TTY_CSI_MODE`, stored, and applied to the live
console with one `TTY_HW_SET`, before the geometry validation. `vidmode
onehead` / `vidmode dualhead` speak it with cols=0 (geometry unchanged), so
the existing setter and its trivial read-back (nothing to verify -- head
mode is not in `SYS_TTYGEO`) carry it with no new emit path.

`UT_VID_PASS` (ultraterm.s) is the inverse of `UT_SEL_PAGE`: it writes
`$C0B2` with VIDSEL clear (page nibble and VTEMU kept), which is how the
card hands the monitor back to the motherboard.
