# SERIAL -- the Super Serial Card, `/dev/ttya0`, and `tip`

Status 2026-09-11: the card, the driver, and the host daemon are landed
(see "What exists"). `tip` is the first program that USES the line; it is
specified in section 3 and tracked as TASKS.md #22.

## 1. What exists

| piece | where | landed |
|---|---|---|
| 6551 ACIA card model (`SscCard`, 2K ROM 341-0065-A, slot 2 default) | verilogapple `sim/ssc/ssc_card.h`, bus wiring in `fast_apple2e.h`, `core::Machine` `install_ssc`/`ssc_slot` | 5ae61f4, b01fe94 (`milestone/remote-mcp-service`) |
| MCP tools `ssc_state` / `ssc_tx_read` / `ssc_rx_write`; `reset {"ssc":true}` | verilogapple `mcp_server.cpp` | b01fe94 |
| maux driver: boot slot-scan for the Pascal signature, tick-hook RX poll into a 256-byte ring, `SER_READ` (blocking, short-read) / `SER_WRITE` (busy-poll TDRE), fd-class `FD_SER0`, `/dev/ttya0` in `PDEV_TAB` | `src/kernel/ser.s`, arms in `procmli.s`/`procmli3.s`/`procfile5.s` | 0f47c6e (`wip/subshell-2`) |
| `serbridge` host daemon: `ChannelRouter` + `PtyBackend`/`ExecBackend`/`LoopbackBackend` + `McpTransport` | `tools/serbridge/` | 7a88e52 |
| gates | `make check-ser` (fast backend, `reset {ssc:true, clock:false}`), `make check-tip`, `make check-tip-vim` -- all three in `CHECK_ALL_TARGETS` since SER-1 (2026-10-20); check-tip-vim is on the box list again (PACE-1: the box failure was vim 9.0 clearing IXON so the guest's XON became CTRL-Q; the rig restores IXON, docs/PACE-1-NOTES.md sec 0d); `tools/serbridge/test_router.py` | |

Facts the design leans on (all `[fact]`, sources in the commons):

- The SSC is a 6551. Period II/II+ software drives it POLLED (SW2-6 off);
  the //e may take its IRQ. maux V1 is polled: once per tick from
  `TTY_TICK` (`SER_POLL`). Manual: `learning:01M27HT1E4QBBFKGARYWBMMGRE`;
  ROM map: `learning:01M27KGKPYZD5HY0TA3FSRDT63`.
- Slot 2 collides with the authentic Timemaster clock's `$C200`. maux
  finds the card by signature scan, so it can sit in ANY slot; the
  interactive runner puts it in slot 1 (the period "printer" slot) and
  keeps the clock.
- Tick-context wake-ups must restore the process bank
  (`learning:01M28001EKW3KDXM109P97AJHH`) -- `SER_POLL` does.
- The console's raw reader hands bytes with the HIGH BIT SET (`$8D` for
  RETURN) and frames a physical arrow as `$9B $DB $C1..$C4` (ESC [ A..D);
  `TTY_PUT_NORM` drops output bytes >= `$7F`. So a terminal program must
  strip bit 7 on the way OUT to the line and pass only 7-bit bytes to the
  console. ^C and ^Z are intercepted upstream of the ring in every mode
  (`SYS_TTYMODE` contract): a program sees them only as a held signal
  (`SIGA_CATCH` -> `ERR_INTR` out of a blocked read + `SYS_SIGPEND`).
- `SC_FORK` copies the fd TABLE; a tty/device fd is a constant handle, so
  both halves of a forked terminal program can use `/dev/ttya0` and the
  console (docs/FORK.md "fd duplication").

## 2. Throughput and the emulated modem (S1, verilogapple)

The card model holds ONE byte each way (`rx_data`/`tx_data`), which is
the bare 6551 -- and the host reaches it through MCP polling, so a burst
from the host overwrites bytes the guest has not read, and a burst from
the guest overwrites bytes the host has not drained. Fine for a
three-byte gate; useless for a shell session.

S1 gives the HOST side of the card FIFOs (the guest-visible registers do
not change):

- `host_deliver_rx(b)` queues; the DATA register is refilled from the
  queue on every guest DATA read, so `RDRF` stays set while the queue is
  non-empty. `ssc_rx_write` and the socket bridge push into it.
- `host_take_tx` pops a TX queue; a DATA write appends. `TDRE` stays set.

This is "the modem is infinitely fast" -- an emulation convenience, NOT
6551 behaviour, and it is where a baud-rate pacing knob would go later
(TDRE cleared for `1.023M / (baud/10)` cycles per byte, from the CONTROL
register's baud bits). Recorded in ANACHRONISMS.md as an emulator-side
entry, not a maux one.

The interactive runner `fast_sdl` gains `--ssc [slot]` (default slot 1)
and `--ssc-socket PATH`: a Unix stream socket the runner LISTENS on;
once a client connects, every frame the runner drains the TX queue to
the socket and reads whatever the socket has into the RX queue. Raw
bytes both ways, no framing -- the socket IS the RS-232 line. This is the
`SocketTransport` the serbridge README already names as its third
transport.

### 2a. maux side (S3)

`SER_POLL` drains in a LOOP while `RDRF` is set and the ring has room
(<= 255 bytes per tick), instead of one byte per tick. With a real card
at 9600 baud that is 16 bytes per tick; the loop is what keeps a
60 Hz poll from being a 600-baud ceiling. Ring full still drops (a
dropped byte beats a wedged receiver; no flow control in V1).

## 3. `tip` (S4, maux userland)

`tip` connects the console to `/dev/ttya0`: what you type goes out the
line, what comes in is painted. 4.2BSD `tip(1)` (1983) is the name the
operator asked for; V7's `cu(1C)` is the same program with a smaller
escape set. Period-clean either way.

### 3a. Process model -- fork, the way tip and cu do it

```
tip
 |-- parent: console -> line     (raw+no-echo console, catches ^C/^Z,
 |                                recognises ~ escapes at line start)
 `-- child:  line -> console     (SER_READ blocks; strips bit 7; passes
                                  bytes through UNCHANGED -- ignores ^C/^Z)
```

**No CR/LF fold since VT102 slice 1 (2026-09-12, docs/CONSOLE-VT102.md).**
tip's console stays mode 0 (strict VT102, `TMD_OPOST` clear): the terminal
layer's own CR (column 0 only) and LF (column 0 + advance) already render
a host `\r\n` pair as one line break, so folding it here would double up
on what the console now does itself. Bit 7 stripping stays -- the host's
high bit is not maux's.

The console is a two-stage polled pipeline with no select(); a single
process cannot wait on both the keyboard and the line. Two processes can,
and `SC_FORK` costs one bank. The child never reads the console; the
parent never reads the line.

### 3b. Parent (keyboard half)

1. `SC_OPEN /dev/ttya0` (fail: "tip: /dev/ttya0: no such device", exit 1).
2. Save the console mode: `SC_TTYMODE(FD_STDOUT, 0)` -> raw, no echo;
   remember the previous flags.
3. `SC_SIGNAL(2, SIGA_CATCH)` and `SC_SIGNAL(SIG_TSTP, SIGA_CATCH)`.
4. `SC_FORK`; child -> 3c.
5. Loop: `SC_READ` FD_STDIN, 1..3 bytes.
   - `ERR_INTR`: `SC_SIGPEND`; signo 2 -> send `$03` to the line;
     SIG_TSTP -> send `$1A`. (A terminal program forwards the interrupt
     to the remote; that is what tip does with an unescaped ^C.)
   - Strip bit 7 on every byte (`$8D` -> `$0D`; a framed arrow becomes
     `ESC [ A`, which the host understands as-is).
   - Escapes, recognised ONLY at the start of a line (previous byte was
     CR, or nothing typed yet), as in tip:
     `~.` disconnect; `~?` print the escape list; `~~` send a literal `~`.
     Anything else after `~` sends the `~` and the byte. V2 candidates:
     `~!` (local shell), `~^Z` (suspend tip), `~>`/`~<` (file transfer).
6. On `~.`: `SC_KILL(child, 15)`, `SC_WAIT`, restore the saved console
   mode (cooked+echo -- every raw-to-shell handoff restores it; see the
   vi ^Z lesson), print `[EOT]`, `SC_CLOSE`, exit 0.

### 3c. Child (line half)

`SC_SIGNAL(2, SIGA_IGN)`; `SC_SIGNAL(SIG_TSTP, SIGA_CATCH)` (the ^Z sweep
direct-stops a non-catcher DESCENDANT of the foreground job, and nothing
would ever continue it -- catch and discard instead). Loop: `SC_READ`
`/dev/ttya0` into a 64-byte buffer; `and #$7F` every byte IN PLACE; `SC_WRITE`
the whole read in one call to FD_STDOUT -- no CR/LF fold (VT102 slice 1,
2026-09-12): the console's own terminal layer, running strict VT102 on
this raw console (`TMD_OPOST` clear), already renders a host `\r\n` as one
line break (CR returns the column, LF advances), so folding here would be
redundant work undoing what the fold used to paper over. `ERR_INTR` ->
`SC_SIGPEND`, continue. The child exits only by the parent's kill.

### 3d. What is deliberately NOT in V1

No carrier detect (the line never "hangs up" -- only `~.` ends a
session); no baud/`stty` on the line; no file transfer; no `~!`. Each
is a named gap, not an accident. Flow control WAS a gap until
2026-09-12: host vim's first screen (1.2 KB in one burst) outran the
console and the ring-full-drop rule lost bytes, so the driver now speaks
XON/XOFF -- `SER_POLL` stops reading at 192 ring bytes and sends DC3,
`SER_READ` sends DC1 at 64 -- and the host pty's IXON pauses the writer,
the way any 1981 host paused a VT102 (its terminfo declares `xon`).
Gate: `make check-tip-vim`, which was red for exactly this before.

#### Flow control and remote programs (SER-2, closed by ruling 2026-10-21)

maux throttles the remote IN BAND: DC3 when its receive ring nears full,
DC1 when it drains. That works only while the remote program leaves
IXON set on its tty. A program that clears IXON gets the two bytes as
KEYSTROKES. Measured (docs/PACE-1-NOTES.md sec 0d): Debian's vim
9.0.1378 clears IXON when it goes raw, so maux's DC1 arrives as CTRL-Q,
which in vim is blockwise Visual mode; vim 9.1 leaves IXON on and the
remote line discipline eats the byte. maux throttles on any large
repaint (it paints slower than the line delivers), so a remote program
that clears IXON will see the keystroke whenever the screen is redrawn.

Hardware flow control is not the way out. The 6551 drives RTS from
COMMAND bits 3-2, and the only value that raises RTS (00) also turns
the transmitter OFF -- holding RTS off would stop maux's own keystrokes
(`learning:01M5DF1W8XXNWB96N99WK4AQ44`, table from the Synertek figure in
the IIc Technical Reference, Fig 11-43). A per-byte switch around each
transmitted character is not safe either: TDRE is not shifter-empty, so
switching the transmitter off at TDRE can truncate the last character.
The driver therefore stays XON/XOFF only and has no RTS mode.

Workarounds, on the remote side: use vim 9.1 or later, or any remote
program that leaves IXON on (`stty ixon` before starting it, if it does
not reset the flag itself). Detail: docs/SER-2-NOTES.md.

### 3e. Gate: `make check-tip`

Headless, local fast backend, `reset {ssc:true, clock:false}` (the same
rig as check-ser), the person-like `e2e_term` harness, on the play image:

1. `tip` at the prompt -> the prompt is gone; `ssc_tx_read` is empty.
2. Type `ls -l` RETURN one key at a time -> `ssc_tx_read` yields exactly
   `6C 73 20 2D 6C 0D` (bit 7 stripped, RETURN = `$0D`, nothing echoed
   locally: the screen row is unchanged).
3. `ssc_rx_write` `"total 3\r\nfoo\r\n"` -> two screen rows `total 3`,
   `foo`, no blank row between -- the console's own CR(col0)/LF(advance)
   terminal layer renders the pair as one line break now (VT102 slice 1;
   tip no longer folds this itself).
4. ^C -> `ssc_tx_read` yields `03`; tip is still running.
5. Type `~` `?` -> the escape list paints; `~` `~` -> `7E` on the line.
6. RETURN then `~` `.` -> `[EOT]`, the shell prompt returns, and typing
   `echo ok` ECHOES (cooked+echo restored -- the gate the ^Z bug taught).
   `ps` shows no leftover child.

Teeth: drop the mode restore -> case 6 red. (The old "drop the CR-LF
fold -> case 3 red" teeth retired with the fold itself, 2026-09-12 --
case 3 now exercises the console's TMD_OPOST-independent CR/LF handling
instead, see docs/CONSOLE-VT102.md sec 5's own teeth on that mechanism.)

### 3f. Live use (S5)

```
# terminal 1: the machine, SSC in slot 1, line on a socket
sim/fast/fast_sdl --sdl --disk build/play.po --ssc --ssc-socket /tmp/ssc.sock
# terminal 2: the host end of the line -- your shell on a pty
python3 -m serbridge --transport socket --socket /tmp/ssc.sock \
        --backend exec --exec "$SHELL"
# in the maux window
$ tip
```

The console is a 7-bit VT102 and, like the real one, discards bit 7 as
parity -- so a UTF-8 em-dash (`E2 80 94`) from the host would paint as
`b`, NUL, ^T (seen live on HACKING.md, 2026-09-12). serbridge folds each
UTF-8 code point it cannot send to one `?` (`SevenBit` in backends.py;
`--8bit` passes raw bytes for a host program that means them).

serbridge (S2) gains `SocketTransport` and runs `--exec` commands on a
PTY (`pty.fork`), not pipes -- a shell on pipes has no job control and
`vi` on the host would not work. `TERM` is exported as **`vt102`**, the
console's own target (docs/CONSOLE-VT102.md), and the pty's window size
is set to the console geometry (`--cols`/`--rows`, 80x24). This line
read `dumb` until 2026-09-11 and was stale from the day the PTY landed:
`dumb` would tell a host curses program it has no cursor addressing, and
the point of the PTY is that `vi` -- and anything else full-screen --
works. `check-tip-vim` is the gate that says it does.

## 4. Order

S1 (verilogapple FIFOs + `--ssc`/`--ssc-socket`) -> S3 (`SER_POLL` loop)
-> S4 (`tip` + check-tip) -> S2 (serbridge socket transport + pty exec)
-> S5 (live). S4's gate needs S1's RX FIFO to inject a burst.
