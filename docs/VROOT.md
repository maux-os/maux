# VROOT -- the virtual root: a kernel-owned `/`, the boot volume mapped into it, every volume under `/mnt`

Status: LIVE (landed on main 2026-10-10, bcacf51; KFIX5 `/mnt/NAME`
refusal 2026-10-18; KFIX9 op 5 CLASSIFY). The kernel half is
`src/kernel/vroot.s` (translation, reverse map, `SYS_VROOT` op 3) with
`VR_OTHER` in `src/kernel/procdev.s` (ops 0-2) and the loop ops in
`src/kernel/loopseg.s`; the user half is `mount`, `umount`, `df` and
the `/bin` search path (`src/liba/pathtab.s`). Gates: `check-mount`
(the path rows, `..`, the read-only `/`, KFIX5), `check-devfs`,
`check-volname`, `check-loop`. This is the only place the `SYS_VROOT`
ops table, the path-mapping rulings and the `/mnt` `/bin` `/usr`
mapping are written down (`docs/DEVFS.md` covers `/dev`;
`docs/SYSCALL.md` lists the call number only). The last section lists
where the built system differs from the design this document started as.

## The rulings this implements (operator, 2026-10-08, in order given)

1. `/bin` is the boot volume's `BIN`; `/usr` is the boot volume's `USR`.
2. "/basic is a shit name for maux's volume." The boot volume is renamed.
3. "we could shunt it into /mnt and make it all purty" / "virtual root is
   a thing" / "now we're making something great. familiar structures.
   complete tools."
4. The decisive one, choosing between two designs: "it's a toss up - do
   we do virtual root or do we take the boot volume and suppress its
   volume name into a virt root. I think the former, as it allows the
   various unix filetypes to exist without forcing ProDOS to accomodate
   them."

So: **`/` is a directory the KERNEL owns, not a directory on any disk.**
It is a small table of named entries, each of a Unix kind, and the
boot volume's directories are MAPPED into it. ProDOS stores files; the
kernel stores the namespace above them. That is what lets Unix object
kinds (a mount point, a device directory, later a symbolic link or a
fifo) exist without inventing ProDOS file types for them, and it is why
`ls /` shows a Unix root and not `PRODOS`, `MAUX.SYSTEM`, `KSEG`,
`BYERES`, `TENANT.SYSTEM`: the plumbing stays on the volume, reachable
under `/mnt/MAUX/`, and out of sight.

```
/            kernel table (read-only: creating or removing an entry in
             `/` is refused, EROFS-shaped; mkdir/rmdir/creat/rename
             naming `/X` directly fail loudly)
  bin   ->  <boot>/BIN        a directory map
  usr   ->  <boot>/USR        a directory map (/usr/man = today's /BASIC/MAN)
  etc   ->  <boot>/ETC        a directory map
  tmp   ->  <boot>/TMP        a directory map (a RAM volume later, by table edit)
  dev   synthetic             docs/DEVFS.md, unchanged
  mnt   synthetic             MOUNTED volumes by name (see below)
/mnt/MAUX/bin  the same directory as /bin; /mnt/MAUX/PRODOS etc. visible here
```

The table is data (name, kind, target; `VR_TAB`); `/tmp` moving to a
RAM volume one day is a table entry, not a design. **Room was left in
the KIND for a generated directory**: the operator named `/proc` the
same night ("and it creates the opportunity to do /proc"). It is NOT
built, but the intent stands: the kind field, the readdir dispatch for
synthetic directories (a per-kind lister, the shape `/dev` has) and the
OFT must not assume every non-map entry is `dev` or `mnt`. A
`/proc/<pid>/status` would be a char-device-shaped OFT whose read
renders PCB text, as `/dev/null`'s read renders nothing, and `ps`
would become a reader of it. Adding the row touches the table and one
lister, not the resolver. The boot volume name is NOT a
constant: it is what `PRC_PFXSAVE` captured on the first chdir ("the
boot volume, since nothing has moved it", procfile.s `PRC_SETPFX`).

The design NOT taken, for the record: making the boot volume's own
root directory `/` with `dev` and `mnt` spliced into its listing. It is
~100 B cheaper (a constant prepend instead of a first-component lookup)
but it puts every ProDOS plumbing file in `/`, inherits 2.4's 51-entry
root cap as `/`'s own, and leaves no place for an object ProDOS cannot
store.

## Mechanism: one lookup, two directions, one place

The kernel has one chokepoint for pathnames, `PRC_CANONPATH`
(procfd2.s): an absolute path is copied verbatim; a relative one is
appended to the per-process cwd (`PRC_GETPFX` answers from the caller's
own cwd slot -- docs/CD.md; the machine-wide ProDOS prefix is pinned back
to the boot volume after every cd, `PRC_PIN_BOOT`).

* **Virtual to physical (into the MLI, `VR_XLATE_P`):** after
  canonicalisation, look the FIRST component up in the root table
  (`VR_LOOK`, case-folded). A directory map rewrites
  the component to its target (`/bin/sh` -> `/MAUX/BIN/sh`: the boot
  volume name is put in front, `VR_INS`); `/dev/...` goes to
  `VR_DEVCALL` and never reaches the MLI; `/mnt/NAME/...` becomes
  `/NAME/...` (`VR_DEL` drops "/mnt"); a bare `/`, `/mnt` or `/mnt/`
  with nothing after it, or a component not in the table, is
  `ERR_NOENT` as an MLI target (nothing else lives in `/`; listing
  `/`, `/dev` and `/mnt` is synthetic).
* **Physical to virtual (out of the MLI):** `PRC_GETPFX` and every path
  the kernel hands back are reverse-mapped: a physical prefix under a
  mapped directory of the boot volume prints as its `/name` (longest
  match wins, so `/MAUX/BIN` is `/bin` not `/mnt/MAUX/BIN`); anything
  else on any volume prints as `/mnt/NAME/...`. The boot volume's root
  itself is `/mnt/MAUX`. readdir hands back entry names, not paths;
  untouched.
* **The cwd slot stores PHYSICAL.** Only the syscall boundary
  translates. `bye`'s tenant, `PRC_PIN_BOOT`, and io_buffer lending's
  reopen paths (`learning:01M1WQP0J05MFRR0B03X6MB0ZR` -- relative
  reopens are pinned for exactly this reason) keep seeing ProDOS paths.
  `cd /` is legal (cwd = the table; `pwd` prints `/`; a relative open
  there is `ERR_NOENT` unless its first component is a table entry).
* **`..` at the top.** The pseudo-root has broken a `..`-popper once
  (`learning:01M3RZKJ0Z9KKY7H0HPPJR7ERE`). `cd` and `find` resolve `..`
  in userland (liba `MKP_DOT`/`MKP_POP`) on the virtual text; the
  kernel has no `..` machinery of its own for this (the original
  design had `PRC_DOTDOT` serve SET_PREFIX). After `cd X; cd ..`:
  `/bin` -> `/`, `/mnt` -> `/`, `/dev` -> `/`, `/mnt/MAUX` -> `/mnt`,
  `/mnt/MAUX/BIN` (which prints as `/bin`) -> `/`. `..` at `/` stays
  `/`. check-mount has rows for each, through `cd` AND `find ..`.
* **readdir of `/`:** the table, in table order, each row typed by its
  kind (directory for the maps and for `mnt`, directory for `dev` as
  today). readdir of `/mnt` is today's `RD_READROOT` volume scan, moved,
  filtered by the mount bit below. `/mnt/<vol>` is that volume's root,
  by translation. Names are high-bit display text
  (`learning:01M3RZK4VC362JNFJGBXRAH3SH`).
* `PATHTAB` (src/liba/pathtab.s) is `/bin/`. `sh` lives in `BIN`
  (nothing in `/` is a binary); the kernel's boot path is physical.

**KFIX5 (2026-10-18): a path under `/mnt/NAME` is refused for a name that
is not mounted.** VR_XLATE's `:mnt` arm asks `VR_MNTCK` (loopseg.s; stub in
procdevs.s) before it strips "/mnt": NAME must be the boot volume, a fast
unit's volume (one ON_LINE of each) or a Disk ][ the user mounted; otherwise
`$45` and no MLI call, so ProDOS's search of every drive never starts. The
listing already showed mounted volumes only; path access now agrees.


Every "no such volume" form answers the same `$45` (ProDOS's own
volume-not-found): an unmounted name, `/mnt//x`, a name over 15
characters (architect ruling, KFIX5 review F5: one error for one
condition). A non-boot name that passes costs one ON_LINE per fast unit
once, then the last found name is cached (VR_MNTCK, loopseg.s) until a
mount, umount, loop attach/detach or `bye`; a removable medium swapped
for another name keeps the old name accepted until then.

## SYS_VROOT: the ops (syscall 25; the ABI as of KFIX9)

Parmlist, 4 bytes: `+0 op`, `+1/+2` a pointer (an MLI-shaped,
count-prefixed path, or a buffer), `+3 arg`. Result in A, carry
set on error (the code is the kernel's `K_RESULT`). inc/sc.proc.equ
carries the same table.

| op | name | in | out |
|---|---|---|---|
| 0 | ROW | arg = row index | the VR_TAB row at the pointer (`[n+1][name][kind]`); a length byte of 0 ends the table |
| 1 | MOUNT | arg = unit (DSSS0000) | a Disk ][ is marked mounted; any other unit is a no-op; no such unit is `$28` |
| 2 | UMOUNT | arg = unit, pointer = `/NAME` | a mounted Disk ][ is unmounted, or the loop (unit `$B0`) detached; a fast unit or the boot volume is refused (`ERR_INVAL` / busy); a file open or parked on NAME, a cwd on it, an open block device on the unit, or the loop's host volume is `MLIE_FILOPEN`; the loop detach reports blocks not written |
| 3 | PHYS | pointer = a virtual or relative path | the PHYSICAL path comes back at the pointer (`df`) |
| 4 | LOOPATT | pointer = the image path, arg = the unit holding its volume (high nibble) with bit 0 = `-r`, bit 1 = re-attach what `bye` detached | attaches unit `$B0` (play image; docs/LOOP.md) |
| 5 | CLASSIFY | pointer = any path | A = 0 an ordinary path, `$80` `/`, `$81` `/dev`, `$82` `/mnt` (play image) |

Ops 0-2 are in procdev.s (`VR_OTHER`), op 3 in vroot.s (every image
has it: `df` needs it), ops 4 and 5 enter through `LP_OP45` in the low
segment (loopseg.s), which sends 4 on to `VR_XLATE_P` + `LP_ATTACH` and
5 to `LP_CLASS`. The other images' `VR_OTHER` is the stub in
procdevs.s. An op number above 5 is `ERR_INVAL`. The table rows are
stored upper case (`BIN USR ETC TMP DEV MNT`); ROW hands them back
lower case, followed by the kind byte (1 directory map, 2 synthetic
device directory, 3 `/mnt`; `VK_MAP/VK_DEV/VK_MNT`, inc/proc.const.equ).

**Op 5, what it answers and how.** The question is the one `ls`,
`find`, `cp ...` and sh's glob ask before they open a directory: does
this path NAME one of the three directories the kernel owns? It is
answered AFTER the cwd is joined (PRC_ABSPATH), and "." / ".." / empty
components are resolved, so `mnt` from `/`, `.` from `/mnt`, `..` from
`/dev` and `/dev/../mnt` are all one question. It builds no string.
Two facts survive every pop and decide the answer: the DEPTH (components
on the stack) and the FIRST component's row kind (set when the depth
goes 0 -> 1, from VR_LOOK). Depth 0 is `/`; depth 1 with kind DEV or
MNT is `/dev` or `/mnt`; anything else is 0. `..` at depth 0 stays
there. A path typed absolute, or joined to a synthetic cwd, is VIRTUAL
(VR_PEND); one joined to a real cwd is PHYSICAL and VR_REV spells it
virtually first -- the CWD only, never a component the user typed (a
cwd of `/MAUX/BIN` is `/bin`, so `..` is `/`; at the volume root
`BIN/../..` is `/mnt`, not `/`) -- (a volume that is not the
boot volume's gets `/mnt` in front). A path still relative with no cwd
means ProDOS's prefix, the boot volume's root: `/mnt/MAUX/`, depth 2.
An empty path answers 0. A joined path that would pass 64 bytes is
refused by the copier (the error comes back; liba reads it as 0). This
replaced readsyn.s's RD_SYNCHK + RD_CANON, 257 B in every program that
puts readsyn.s (docs/KFIX9-NOTES.md sec 1).

## `mount` and `umount`

* Kernel: a per-unit MOUNTED bit for slow units (`K_MNT`, beside the
  `PDL_REC`/DEVLST classification in kdevblk.s that tells a Disk ][ by
  the DEVLST flag). Fast units are implicitly mounted. `/mnt`'s listing
  is the fast units' ON_LINE names plus the slow units with the bit set
  (their name read by ONE ON_LINE on that unit at mount time, never
  unit 0 -- the one sanctioned poll of a Disk ][, because the user
  asked).
* `mount` with no operand lists what is mounted, one line per volume:
  `/dev/s7d1 on /mnt/MAUX` (boot volume first, then slot, then drive;
  `docs/man/mount.1`). `mount /dev/s6d1` sets the bit and reads the name
  (a drive with no readable ProDOS volume fails with the MLI's own
  reason -- `$52` not ProDOS, `$28` no device -- and sets nothing);
  mounting a fast unit succeeds and does nothing. `umount /dev/s6d1` or
  `umount /mnt/GAMES` clears the bit; it is refused while a file on the
  volume is open or parked, a cwd is on it, or a block device is open
  on the unit (lending's parked files count -- `PRC_FILE_BUSY` /
  `PRC_ANCESTBSY` are the precedent), and the boot volume never goes.
* The same verb attaches disk images (`mount IMAGE.po`, op 4; the loop
  device is just another named slow unit, `/dev/s3d2`; docs/LOOP.md).
* `df` enumerates by `SYS_DEVLIST` without polling a Disk ][ and shows
  mounted floppies by the same bit; it asks the kernel for each
  filesystem path's physical form (op 3).

## The volume name

The boot volume is `MAUX` (it was `BASIC`, ruled a "shit name" in
ruling 2). Because the virtual root hides the volume name, nearly every
`/BASIC/...` literal in the tree became the plain virtual form, so the
name left the corpus instead of being replaced in it. `MAN` moved to
`USR/MAN` (`man` reads `/usr/man`); `PATHTAB` is `/bin/`; `sh` lives in
`BIN`. `check-volname` enforces it: no slash-BASIC path literal in
scripts, src, live docs or man pages, and the volume on every built
maux image is `MAUX`. Older history documents still say `/BASIC/`; read
it as `/`.

## Limits

* **A typed path is capped at 64 characters in its VIRTUAL form** (the
  kernel's two pathname slots and liba's `MKPATH` buffers are 65 bytes
  and hold what was typed). A map that gains the boot volume name
  (`/bin/x` -> `/MAUX/BIN/x`) can also overflow the 64-byte MLI limit
  after translation: `VR_INS` refuses that `ERR_INVAL`. Under `/mnt` the
  physical form is shorter than the typed one, so four characters of
  MLI room are unreachable (docs/KNOWN-LIMITATIONS.md).
* A map target has ONE canonical name: `cd /mnt/MAUX/BIN` then `pwd`
  prints `/bin/`.
* `/` is read-only: `touch /X`, `mkdir /D`, `rmdir /mnt`, `rm /bin`
  each fail with exit 1 and `ls /` is unchanged. It has no entry cap;
  the 51-entry root cap on ProDOS 2.4 stays the VOLUME root's
  (`/mnt/MAUX`).
* `..` is resolved in USERLAND on the virtual text (`cd`, `find ..`,
  liba `MKP_DOT`/`MKP_POP`); an `..` EMBEDDED in an absolute path
  (`/mnt/MAUX/..`) is resolved by nothing and ProDOS rejects it.
* `bye` and `proshim` programs see PHYSICAL names (`/MAUX/...`), never
  `/mnt/MAUX/...` or `/bin`: the one translation boundary left alone.
* `/proc` is NOT built (see sec 8). A removable medium swapped for
  another name keeps the old name accepted by `VR_MNTCK` until the next
  mount, umount, loop attach/detach or `bye`.
* Cost at landing: MAUXPLAY flat headroom 1,079 -> 349 B; MAUXEXPR, the
  tightest stub image, had 7 B below its ceiling, so the next UNIVERSAL
  kernel byte needs a stub-image KSPACE-style stream.

## Gates

* `check-mount` (33 rows when it landed, red on an image without the
  virtual root): `/` is a table and read-only; `..` from `/bin`,
  `/mnt`, `/dev`, `/mnt/MAUX`, `/mnt/SECOND/SUB` (through `cd` AND
  `find ..`); KFIX5 -- `/mnt/GONE`, a 16-character name and an
  unmounted floppy are refused with the four Disk II counters
  unmoved; `mount`/`umount` listing and busy refusals.
* `check-devfs`: `/` lists the six rows (`bin dev etc mnt tmp usr`);
  `/mnt` lists automounted fast units and explicitly mounted floppies;
  the Disk ][ never-poll counters stay zero until a `mount` names one.
* `check-volname`: the volume is `MAUX` everywhere.
* `check-bye`: the tenant still gets a physical prefix.
  `check-dirfull`'s 2.4 leg names the VOLUME root, `/mnt/MAUX`.

## Library notes

* `learning:01M3RZKJ0Z9KKY7H0HPPJR7ERE` -- the pseudo-root vs the
  userland `..`-popper; the bug class this change re-arms.
* `learning:01M10CRQ2V3MC3HN6X835VZS89` -- ProDOS has ONE prefix; the
  per-process cwd is a kernel table, and `( cd X ; ... )` is the test.
* `learning:01M154VXS61SBQVMP8E1HQAQ1X` -- partial pathnames save no disk;
  the translation adds parse bytes, never block reads; depth is capped
  by the 64-byte physical form.
* `learning:01M1WQP0J05MFRR0B03X6MB0ZR` -- lending's reopen paths are
  absolute and physical; keep them so.
* `learning:01M0PBKZKZE55J4NE93TYNJCPC` -- `.` and `..` resolve differently
  per MLI call; rows through GET_FILE_INFO and through readdir both.
* `learning:01M07A3XXC1SS5SQYH4CZCPV44` -- the 51-entry root cap on 2.4
  stays the VOLUME root's (`/mnt/MAUX`), which the kernel-owned `/`
  deliberately does not inherit; KNOWN-LIMITATIONS words it that way.
* `learning:01M3RZK4VC362JNFJGBXRAH3SH` -- synthetic rows are high-bit
  display text; `mnt` sorts beside `dev`, not before `BIN`.
* `learning:01M2MCYEXW7JA7ZPZ4F7GC2217` -- copyin/copyout refuse process
  addresses at or above `$D000`; any string the translation hands back
  must land in a main-window buffer.

## Where the build differs from the original design

Verified against `src/kernel/vroot.s`, `procdev.s`, `loopseg.s`,
`scripts/check_mount.py` and `docs/KNOWN-LIMITATIONS.md`.

* **The 64-byte cap is not applied to the PHYSICAL form only.** The
  design moved the `cmp #65` after the lookup; the cap stayed on the
  typed (virtual) text, and `VR_INS` additionally refuses a translation
  that grows past 64 (see Limits).
* **The kernel's `..` machinery is gone.** The design had `PRC_DOTDOT`
  serve `SET_PREFIX` with explicit `/bin/..` and `/mnt/MAUX/..` rows;
  what runs is userland popping (`cd`, `find`) on the virtual text, and
  an embedded `..` in an absolute path is not resolved. (Comments in
  `src/bin/realpath.s` and `src/liba/mli.s` still name `PRC_DOTDOT`.)
* **The kind field is `1 map / 2 dev / 3 mnt` only.** The design asked
  that the table, the lister dispatch and the OFT leave room for a
  generated directory (`/proc`, operator, 2026-10-08: "it creates the
  opportunity to do /proc"; `ps` would become a reader of it). The row
  format (`VR_TAB`) and `VK_*` kinds allow it; no generated kind, lister
  or `/proc` exists. Adding it is one table line and one lister.
* **`/tmp` is a directory map onto the boot volume's `TMP`**; the RAM
  volume remains "later, by table edit".
* **Ops 4 and 5 were added after the design** (the loop device,
  KFIX9), and the `VR_OTHER` header comment still says "ops 0, 1, 2".
  Op 5 replaced readsyn.s's RD_SYNCHK + RD_CANON (257 B in every
  program that puts it).
* **`mount` lists the boot volume first, then slot, then drive;** the
  landing note called the order DEVLST order (an open ruling then).
