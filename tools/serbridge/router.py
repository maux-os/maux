#!/usr/bin/env python3
"""router.py -- the channel router core for serbridge.

This module knows NOTHING about PTYs, subprocesses, sockets, or MCP. It
knows only two small interfaces (Backend, Transport) and a table mapping
channel id -> Backend. That separation is the whole point of slice 3:
today there is one channel (the emulated Super Serial Card) and one
transport (McpTransport), but a future "super duper" quad-UART/MCU
coprocessor card is modeled as MORE ENTRIES in the same table plus a
different Transport -- this file does not change.

Data directions, named from the guest's (the emulated Apple IIe's) point
of view, matched to the MCP tool names given for the SSC:
  guest TX  -- bytes the 6502 program wrote to the card, now arriving at
               the host. Transport.read_from_guest() drains these;
               Router hands them to the channel's Backend.from_guest().
  guest RX  -- bytes the host wants the 6502 program to read from the
               card. Backend.to_guest() produces these; Router hands
               them to Transport.write_to_guest().

Both interfaces are deliberately synchronous and non-blocking: every
method must return promptly (empty bytes / no-op when there is nothing
to do) so one Router can pump many channels in a plain poll loop without
threads. See SELECT_TIMEOUT in backends.py for how the pty/exec backends
honor that contract.
"""
import abc
import time


class Backend(abc.ABC):
    """One channel's host-side endpoint: a PTY, a spawned process, a
    future TCP socket or service. The router only ever calls these two
    methods -- nothing in router.py imports a concrete Backend."""

    @abc.abstractmethod
    def to_guest(self):
        """Return bytes ready to be injected into the guest's RX, or
        b"" if none are ready right now. Must not block."""
        raise NotImplementedError

    @abc.abstractmethod
    def from_guest(self, data):
        """Accept bytes the guest transmitted (guest TX). `data` is a
        nonempty bytes object. Must not block (buffer internally if the
        sink is momentarily not ready for writes)."""
        raise NotImplementedError

    def close(self):
        """Release any host resources (fds, subprocesses, sockets).
        Default is a no-op; override when there's something to close."""
        pass


class Transport(abc.ABC):
    """How the router reaches the emulator's serial line(s). One
    concrete implementation today (McpTransport, over
    scripts/mcp_drive.py's MCPClient); FakeTransport in test_router.py
    stands in for the emulator in the self-test. A future
    SocketTransport (once the emulator exposes a raw Unix socket for the
    SSC line) implements the same two methods and nothing else in this
    file changes."""

    @abc.abstractmethod
    def read_from_guest(self, channel_id):
        """Drain and return bytes the guest has transmitted on
        `channel_id` (guest TX) since the last call, or b"" if none.
        Must not block."""
        raise NotImplementedError

    @abc.abstractmethod
    def write_to_guest(self, channel_id, data):
        """Inject `data` (nonempty bytes) into `channel_id`'s guest RX.
        Must not block (queue internally if the emulator call is costly;
        a transport MAY choose to batch on the next poll instead)."""
        raise NotImplementedError

    def close(self):
        pass


class ChannelRouter:
    """The router core. Holds a Transport and a {channel_id: Backend}
    table; pump_once() moves one round of bytes in both directions for
    every channel. run() wraps that in a poll loop.

    Transport- and backend-agnostic by construction: this class never
    names pty, exec, tcp, or McpTransport. Adding the quad-channel card
    is "construct more Backends, put them in `channels`, hand the
    router a different Transport" -- no change here.
    """

    def __init__(self, transport, channels):
        """transport: a Transport. channels: dict of channel_id (str,
        or any hashable) -> Backend."""
        self.transport = transport
        self.channels = dict(channels)

    def add_channel(self, channel_id, backend):
        self.channels[channel_id] = backend

    def remove_channel(self, channel_id):
        backend = self.channels.pop(channel_id, None)
        if backend is not None:
            backend.close()

    def pump_once(self):
        """One round: for every channel, drain guest->host bytes into
        the backend, then drain host->guest bytes from the backend into
        the guest. Returns the total byte count moved (either
        direction), so callers/tests can tell whether a pump did
        anything without re-deriving it from queue state."""
        moved = 0
        for channel_id, backend in self.channels.items():
            guest_tx = self.transport.read_from_guest(channel_id)
            if guest_tx:
                backend.from_guest(guest_tx)
                moved += len(guest_tx)

            host_out = backend.to_guest()
            if host_out:
                self.transport.write_to_guest(channel_id, host_out)
                moved += len(host_out)
        return moved

    def run(self, poll_interval=0.02, stop_predicate=None):
        """Pump forever at `poll_interval` seconds between rounds, until
        `stop_predicate()` returns True (checked once per round; default
        None = run until killed/interrupted). A busy-poll with a sleep
        is the right shape here: both Backend and Transport methods are
        non-blocking by contract, so there is nothing to select() on
        across the two different kinds of fd (pty/process fds vs. an
        MCP child's stdio) without a more invasive event loop -- not
        worth it for a daemon whose other end is a ~1-14 MHz emulated
        ACIA."""
        try:
            while stop_predicate is None or not stop_predicate():
                self.pump_once()
                time.sleep(poll_interval)
        except KeyboardInterrupt:
            pass

    def close(self):
        for backend in self.channels.values():
            backend.close()
        self.transport.close()
