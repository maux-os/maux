#!/usr/bin/env python3
"""transport.py -- how serbridge's router reaches the emulator's serial
line(s). router.Transport is the interface; McpTransport is the one
real implementation today, over verilogapple's mcp_worker_fast.

McpTransport talks to two MCP tools on the fast-backend worker (per the
slice-3 task brief -- not yet exercised against a live worker build
that ships them, so the wire shape below is documented as an ASSUMPTION
to verify against a real build, not a [fact]):

  ssc_tx_read  {}                    -> bytes the guest (6502 program)
                                         wrote to the card's TX register
                                         since the last read (guest TX,
                                         i.e. "outgoing" from the IIe).
  ssc_rx_write {"bytes": [int, ...]} -> injects bytes into the card's RX
                                         (guest RX, i.e. "incoming" to
                                         the IIe).

Both tools are called through scripts/mcp_drive.py's MCPClient, which
already carries the house knowledge of this wire protocol (newline-
delimited JSON-RPC 2.0, double-encoded tool results -- see
learning:01KZZ53ZE9QX3W2R3NKC209766 in the street-library commons and
the docstring at the top of mcp_drive.py). serbridge does not
re-implement that; it reuses MCPClient.

SocketTransport (2026-09-11) is that third implementation: fast_sdl
`--ssc-socket PATH` listens on a Unix stream socket and pumps the card
every frame -- raw bytes, no framing, the socket IS the RS-232 line. It
is how a human at the fast_sdl window reaches a host shell through
maux's `tip`; nothing in router.py or backends.py changed for it.
"""
import errno
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from router import Transport  # noqa: E402

# scripts/mcp_drive.py lives at <repo root>/scripts/mcp_drive.py; this
# file lives at <repo root>/tools/serbridge/transport.py.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_SCRIPTS_DIR = os.path.join(_REPO_ROOT, "scripts")


def _import_mcp_drive():
    """Import scripts/mcp_drive.py for its MCPClient, without assuming
    scripts/ is a package (it isn't -- it's flat scripts, same as
    here)."""
    if _SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, _SCRIPTS_DIR)
    import mcp_drive  # noqa: E402
    return mcp_drive


class McpTransport(Transport):
    """Drives verilogapple's mcp_worker_fast via scripts/mcp_drive.py's
    MCPClient. One channel_id is supported today ("ssc", matching the
    task's single Super Serial Card channel); channel_id is accepted
    and validated rather than silently ignored so a second channel
    showing up later is a loud NotImplementedError, not a silent no-op.
    """

    #: channel ids this transport currently knows how to address. A
    #: future quad-channel card adds entries here (or -- more likely --
    #: this whole class gets superseded by a transport that maps
    #: channel_id to a per-channel MCP tool-name pair).
    SUPPORTED_CHANNELS = ("ssc",)

    def __init__(self, supervisor=None, roms_dir=None, env=None):
        mcp_drive = _import_mcp_drive()
        self._mcp_drive = mcp_drive
        supervisor = supervisor or mcp_drive.SUPERVISOR
        roms_dir = roms_dir or mcp_drive.ROMS_DIR

        run_env = dict(env if env is not None else os.environ)
        run_env["VERILOGAPPLE_ROMS"] = roms_dir

        self.client = mcp_drive.MCPClient([supervisor], run_env)
        self.client.initialize()
        self.client.require_tools("ssc_tx_read", "ssc_rx_write")

    def _check_channel(self, channel_id):
        if channel_id not in self.SUPPORTED_CHANNELS:
            raise NotImplementedError(
                f"McpTransport has no route for channel {channel_id!r} "
                f"(supported: {self.SUPPORTED_CHANNELS}); add it here, "
                "not in router.py or backends.py."
            )

    def read_from_guest(self, channel_id):
        self._check_channel(channel_id)
        result = self.client.call_tool("ssc_tx_read", {})
        raw = result.get("bytes", result.get("data", []))
        if not raw:
            return b""
        return bytes(raw)

    def write_to_guest(self, channel_id, data):
        self._check_channel(channel_id)
        if not data:
            return
        self.client.call_tool("ssc_rx_write", {"bytes": list(data)})

    def close(self):
        self.client.close()


class FakeTransport(Transport):
    """Stands in for the emulator in the router's self-test (no MCP,
    no verilogapple worker). Two in-memory byte queues per channel:
    one the TEST fills to simulate "the guest just transmitted this"
    (read_from_guest drains it), one the router fills via
    write_to_guest that the TEST can inspect to see "what the guest
    would have received".

    Lives here (not only in test_router.py) because it is a second,
    legitimate implementation of the Transport interface -- proof by
    construction that router.py depends on the interface, not on
    McpTransport.
    """

    def __init__(self):
        # channel_id -> bytearray "the guest transmitted, not yet drained"
        self._guest_tx = {}
        # channel_id -> bytearray "delivered to the guest so far" (test inspects this)
        self._guest_rx_log = {}

    def _ensure(self, channel_id):
        self._guest_tx.setdefault(channel_id, bytearray())
        self._guest_rx_log.setdefault(channel_id, bytearray())

    def inject_guest_tx(self, channel_id, data):
        """Test helper: simulate the guest transmitting `data` on
        `channel_id` (i.e. what ssc_tx_read would have returned)."""
        self._ensure(channel_id)
        self._guest_tx[channel_id].extend(data)

    def sent_to_guest(self, channel_id):
        """Test helper: everything write_to_guest has delivered to
        `channel_id` so far, as bytes."""
        self._ensure(channel_id)
        return bytes(self._guest_rx_log[channel_id])

    def read_from_guest(self, channel_id):
        self._ensure(channel_id)
        buf = self._guest_tx[channel_id]
        if not buf:
            return b""
        out, buf[:] = bytes(buf), bytearray()
        return out

    def write_to_guest(self, channel_id, data):
        self._ensure(channel_id)
        self._guest_rx_log[channel_id].extend(data)

    def close(self):
        pass


class SocketTransport(Transport):
    """The SSC line as a Unix stream socket, served by fast_sdl
    `--ssc-socket PATH` (verilogapple e60be40): bytes read from the
    socket are guest TX, bytes written to it become guest RX. Raw, no
    framing. One channel ("ssc"), same as McpTransport; the future
    multi-channel card would multiplex here, and this class is where.
    """

    SUPPORTED_CHANNELS = ("ssc",)

    def __init__(self, path):
        import socket
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)          # raises if the runner is not up
        self.sock.setblocking(False)
        self.closed = False

    def _check_channel(self, channel_id):
        if channel_id not in self.SUPPORTED_CHANNELS:
            raise NotImplementedError(
                f"SocketTransport has no route for channel {channel_id!r} "
                f"(supported: {self.SUPPORTED_CHANNELS})")

    def read_from_guest(self, channel_id):
        self._check_channel(channel_id)
        if self.closed:
            return b""
        try:
            data = self.sock.recv(4096)
        except BlockingIOError:
            return b""
        except OSError as e:
            if e.errno == errno.EAGAIN:
                return b""
            raise
        if data == b"":                  # orderly hang-up by the runner
            self.closed = True
            print("serbridge: socket transport -- the emulator hung up", flush=True)
        return data

    def write_to_guest(self, channel_id, data):
        self._check_channel(channel_id)
        if self.closed:
            return
        view = memoryview(data)
        while view:
            try:
                n = self.sock.send(view)
            except BlockingIOError:
                continue
            except BrokenPipeError:
                self.closed = True
                return
            view = view[n:]

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
