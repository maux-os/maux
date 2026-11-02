# serbridge -- host-side serial-bridge daemon (slice 3)

Connects maux's simulated Super Serial Card (SSC) serial line, as
exposed by verilogapple's `mcp_worker_fast`, to a host endpoint: a PTY a
human can `screen` into, or a spawned host process. Python 3, stdlib
only, same house style as `scripts/` (flat files, no packaging magic
beyond what's needed for `python3 -m serbridge`).

## Why three layers

The brief beyond slice 3 is a future "super duper" card: several serial
channels behind one quad-UART/MCU coprocessor, maybe with service
backends (a TCP endpoint, a storage block device, an RTC) bolted on per
channel. Getting that later without a rewrite means drawing the seams
now, even though there's only one channel and one transport today:

```
  Backend  <---->  ChannelRouter  <---->  Transport  <---->  emulator
 (host side                          (how the router reaches
  of a channel)                       the guest's serial line)
```

- **router.py** -- `ChannelRouter`: a `{channel_id: Backend}` table plus
  a `Transport`. `pump_once()` does one round for every channel: drain
  guest TX from the transport into the backend, drain backend output
  into the transport as guest RX. It imports nothing from backends.py
  or transport.py -- it only knows the two interfaces below. Adding the
  quad-channel card is "construct more Backends, put them in the table,
  hand the router a different Transport"; this file does not change.

- **backends.py** -- pluggable per-channel host endpoints, each
  implementing:
    - `to_guest() -> bytes` -- bytes ready for the guest to receive now,
      or `b""` if none (non-blocking).
    - `from_guest(data: bytes) -> None` -- bytes the guest just
      transmitted (non-blocking; buffer internally if needed).

  Implemented: `PtyBackend` (tip in), `ExecBackend` (tip out),
  `LoopbackBackend` (trivial echo, for manual smoke-testing the wiring
  with no host resources). Stubbed, clearly marked `NotImplementedError`
  with a TODO: `TcpBackend` (connect out to host:port) and
  `ListenBackend` (accept a socket) -- same two-method interface, no
  router change needed when they're written for real.

- **transport.py** -- how the router reaches the emulator:
  `McpTransport` polls two MCP tools on a running `mcp_worker_fast`
  (`ssc_tx_read`, `ssc_rx_write`), reusing `scripts/mcp_drive.py`'s
  `MCPClient` rather than re-deriving the wire protocol (newline-
  delimited JSON-RPC 2.0, double-encoded tool results -- see
  `mcp_drive.py`'s own docstring and street-library commons learning
  `01KZZ53ZE9QX3W2R3NKC209766`). `FakeTransport` is the second
  implementation, used by the self-test, with two in-memory byte queues
  standing in for the emulator's guest-TX/guest-RX. `SocketTransport`
  (2026-09-11) is the third: it connects to the Unix stream socket a
  running `fast_sdl --ssc --ssc-socket PATH` listens on. router.py and
  backends.py did not change for it.

Direction naming throughout is from the **guest's** point of view (the
emulated Apple IIe): guest TX = bytes the 6502 program wrote to the
card, now arriving at the host; guest RX = bytes the host wants the
6502 program to read from the card next.

## CLI

```
python3 -m serbridge --help          # from tools/, or with tools/ on $PYTHONPATH
python3 tools/serbridge/serbridge.py --help
```

Tip IN -- a human gets a terminal directly on the emulated IIe's serial
line:
```
python3 -m serbridge --channel ssc --backend pty
# serbridge: pty backend -- connect with: screen /dev/ttysNNN
```
Run that `screen` command in another terminal; keystrokes there go out
the emulated SSC's RX, and whatever the 6502 program writes to the card
appears as output in that `screen` session.

Tip OUT -- the emulated IIe talks to a host process (default `/bin/sh`,
so by default this is "the IIe dials into a host shell"). Since
2026-09-11 the process runs on a PTY with `TERM=dumb` (a shell on pipes
has no job control and screen programs refuse to start); `--exec-pipes`
keeps the old pipe wiring:
```
python3 -m serbridge --channel ssc --backend exec --exec /bin/sh
```

THE LIVE SESSION -- a human at the `fast_sdl` window, maux's `tip`
(docs/SERIAL.md) on the guest side, your shell on the host side:
```
sim/fast/fast_sdl --sdl --disk build/play.po --ssc --ssc-socket /tmp/ssc.sock
python3 -m serbridge --socket /tmp/ssc.sock --exec "$SHELL"
```
`--socket PATH` selects `SocketTransport`: fast_sdl listens on that
Unix stream socket and pumps the card every frame; raw bytes, no
framing -- the socket IS the RS-232 line (verilogapple e60be40).

Both require a running `mcp_worker_fast` reachable the way
`scripts/mcp_drive.py` reaches one (`--supervisor` / `--roms-dir`
override its `SUPERVISOR` / `ROMS_DIR` defaults, same as
`$MAUX_SUPERVISOR` / `$VERILOGAPPLE_ROMS` do for that script).

## The acceptance gate: the router self-test (no emulator needed)

```
python3 tools/serbridge/test_router.py
```

Loops back through `ChannelRouter` using `FakeTransport` (in-memory
queues standing in for the guest's TX/RX) against three cases: the
guest->backend direction in isolation, the backend->guest direction in
isolation, and a full round trip through a real `exec(["cat"])`
backend (an actual OS pipe/subprocess, not just the in-memory fakes).
It then proves its own teeth (house rule: a test isn't done until seen
failing on broken code) by monkeypatching `ChannelRouter.pump_once` to
silently drop the backend->guest direction, re-running the same
assertions and showing them fail, then restoring the real
implementation and re-running clean -- nothing in `router.py` is left
modified by the test. PASS prints a summary and exits 0; any failure
(straight run OR the teeth demonstration not behaving as expected)
exits nonzero.

## Manual smoke test (the live path -- not automated yet)

The router's self-test is the acceptance gate for this slice. The full
chain -- `serbridge.py` <-> a running `mcp_worker_fast` <-> maux's own
in-guest serial driver -- can't be exercised end-to-end from here yet:
maux's serial driver is a sibling slice still in progress, and as of
this writing the `mcp_worker_fast` build checked during this slice's
work does **not** export `ssc_tx_read`/`ssc_rx_write` (`tools/list`
returns 42 tools, neither name among them) -- so even the transport
half can't be driven against a live worker today. `McpTransport` fails
loudly on this (`MCPClient.require_tools` raises a named-tool
`MCPError`) rather than silently doing nothing, which is how this was
discovered.

Once a worker build exports those tools, the manual smoke test is:

1. Build/obtain an `mcp_worker_fast` that has `ssc_tx_read` /
   `ssc_rx_write` (check with `tools/list` the way the command above
   does).
2. `python3 -m serbridge --backend pty`, note the printed slave path.
3. In another terminal, `screen <that path>`.
4. Drive the guest side of the emulated SSC (poke/peek the 6551 ACIA
   registers directly via the `mcp__verilogapple__*` tools, or once
   it exists, maux's own serial driver) and confirm bytes written to
   the card's TX register show up in the `screen` session, and
   keystrokes typed into `screen` show up when the guest reads the
   card's RX register.
5. Repeat with `--backend exec --exec /bin/sh` instead of a human at a
   `screen` session: the guest should see a shell prompt and be able to
   run commands against the host process's stdio.

`McpTransport`'s exact wire assumptions (the shape of `ssc_tx_read`'s
return value and `ssc_rx_write`'s argument) are documented as
assumptions-to-verify in `transport.py`'s module docstring, not as
facts -- verify them against the real tool definitions once they exist,
per `McpTransport._check_channel`/`read_from_guest`/`write_to_guest`.

## Primary-source context (why the design looks like this)

Deposited in the street-library commons (`vintage-apple` collection)
the same day this slice was built, specifically for maux's simulated-
SSC work: the 1981 *Super Serial Card Installation and Operating
Manual* (`learning:01M27HT1E4QBBFKGARYWBMMGRE`) and a verified map of
the genuine 341-0065-A ROM dump (`learning:01M27KGKPYZD5HY0TA3FSRDT63`).
Two points from those worth carrying into any future driver/backend
work on this slice:

- The card is a 6551 ACIA. Period Apple II/II+ software drives it
  **polled**, not via IRQ (`SW2-6 OFF` -- "the Apple II and II+ do not
  handle interrupts"); only //e-class hardware can usefully take the
  6551's IRQ. maux targets the enhanced //e, so it may use the IRQ, but
  polled-first is the period-honest default if the guest-side driver
  needs a fallback.
- The SSC's jumper block *is* the null-modem (DTE/DTE cross-wiring);
  that's a property of the simulated card's personality setting, not
  something this host-side daemon needs to emulate -- `serbridge`
  operates purely on the byte streams each MCP tool already hands it.
