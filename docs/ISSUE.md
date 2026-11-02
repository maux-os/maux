# /etc/issue -- the boot splash

Operator request, 2026-10-28: a line or two of text at startup, "so
it's not just a $". Ruled 2026-11-01, on the first draft: "it needs to
be the sort of perfunctory splash any unix would have" -- the system
says what it is and stops. No greeting, no instruction. The text is

```
maux 1.0 (apple2e)
```

which is `uname -s`, `uname -r` and `uname -n` in BSD's shape, and the
gate holds it to exactly that, so the splash and the machine cannot
drift apart. The draft it replaced ("Type `man man` to read the
manual.") was a tutorial, not a banner.

## Mechanism

pid 1 prints `/etc/issue` on the console, once, before it starts the
console shell (INIT_ISSUE in src/test/playtestb.s: open, one READ of at
most 255 bytes, open /dev/tty, WRITE, close; no child process). A
missing file is the normal case and is silent. R_ISSLEN ($121E in
pid 1's bank) records the bytes printed, for the gate.

It is pid 1 and not `/etc/rc` because rc is a whole `sh` spawn before
the first prompt: build_play_image.py records that shipping a sample rc
timed four gates out on 2026-09-20. V7 has getty print issue; maux has
no getty.

The text is the operator's to change. Source: src/etc/issue (ASCII, LF,
at most 255 bytes, 40 columns wide so a 40-column boot does not wrap).
build_play_image.py stages it at /ETC/ISSUE as maux text -- high-bit,
$8D line ends, type $04 -- the same form `vi` writes and the man pages
ship in. Measured 2026-10-28: the console, `grep` and init's raw write
read the low-ASCII $0D form equally well, so the choice is convention,
not necessity; the gate pins the convention.

## What the splash cost the rest of the suite (box sweep, 2026-10-28)

* Gates that fix the prompt's row boot a copy with /ETC/ISSUE removed
  (scripts/noissue.py): check-play (prompt on row 0), check-play80 and
  check-ut-bold (prompt on card row 0, cursor at col 2), check-rambye
  (the `bye` farewell's row decides which text-page bytes it lands on,
  and the gate compares aux $0600-$07FF). check-issue boots the real
  disk and asserts the splash on both the //e 80-column console and the
  UltraTerm card.
* check-shedit `cap` counted every capital A on the glass; the splash
  has one ("Apple"). It now counts from the row of its own echo.
* The splash must not contain a dollar sign: every boot wait in the
  suite (e2e_term.boot, check_vi.boot) looks for one. check-issue
  refuses it.
* No demo film shows the splash: every demo presses ^L after the boot
  and records from there (scripts/demo_record.py). Their stamps hash the
  disk image, so changing play.po stales them all the same
  (scripts/demo_stamp.py).

## Gate

`make check-issue` (scripts/check_issue.py). Teeth, 2026-10-28:

* `jsr INIT_ISSUE` commented out: RED on the boot screen
  (`['$']` where the issue was wanted) and on R_ISSLEN (0, want 19).
* staged as low ASCII with $0D: RED on the host byte check; the other
  rows stay green (the encoding is convention, see above).
* splash says `maux 1.1 (apple2e)` (2026-11-01): RED, "the splash
  opens 'maux 1.1 (apple2e)', but the machine calls itself
  'maux 1.0 (apple2e)' (uname -s/-r/-n)". The same tooth catches the
  other direction -- a `uname` whose RELSTR moves without the splash.
* The no-file row has no tooth of its own: it passes on any init that
  does not invent text, and no cheap mutation of init makes it print
  something when the open fails.
