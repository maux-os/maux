#!/usr/bin/env python3
"""test_router.py -- serbridge's self-test and acceptance gate.

No emulator needed: the router core (router.ChannelRouter) is exercised
against a FakeTransport (two in-memory byte queues standing in for the
guest's TX/RX, see transport.py) and two backends:
  - a tiny RecordingBackend / CannedBackend pair that isolate each
    direction (guest->backend, backend->guest) one at a time, and
  - ExecBackend wrapping the real `cat` (so there's at least one test
    that exercises an actual OS pipe/subprocess, matching the task
    brief's "or the exec with cat" option) for a full round trip.

Run directly:  python3 tools/serbridge/test_router.py
Exit status:   0 on PASS, nonzero on FAIL (gate-friendly).

Also demonstrates the tests' teeth (house rule: "prove the teeth of
every gate" -- a test isn't done until seen failing on broken code):
pump_once is monkeypatched to drop ONE direction, the same assertions
are re-run and shown to fail, then the router is restored and re-run
clean. Nothing in router.py/backends.py/transport.py is left modified.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from router import Backend, ChannelRouter          # noqa: E402
from transport import FakeTransport                # noqa: E402
from backends import ExecBackend                    # noqa: E402

CHANNEL = "ssc"


class RecordingBackend(Backend):
    """Records what from_guest() received; to_guest() never produces
    anything. Isolates the guest->backend (TX) direction."""

    def __init__(self):
        self.received = bytearray()

    def to_guest(self):
        return b""

    def from_guest(self, data):
        self.received.extend(data)


class CannedBackend(Backend):
    """to_guest() yields a fixed payload exactly once, then nothing;
    from_guest() is ignored. Isolates the backend->guest (RX)
    direction."""

    def __init__(self, payload):
        self._payload = payload

    def to_guest(self):
        out, self._payload = self._payload, b""
        return out

    def from_guest(self, data):
        pass


def _poll_until(predicate, timeout=2.0, interval=0.02):
    """Call predicate() until it's truthy or timeout elapses. Needed
    only for the real-subprocess (ExecBackend/cat) case: a pipe to a
    forked process isn't synchronous the way the in-memory fakes are."""
    deadline = time.monotonic() + timeout
    result = predicate()
    while not result and time.monotonic() < deadline:
        time.sleep(interval)
        result = predicate()
    return result


# ---------------------------------------------------------------------
# Individual assertions, each raising AssertionError on failure. Kept
# as plain functions (not a framework) so the "break one direction and
# show it fails" demonstration below can call the exact same function
# against a tampered router.
# ---------------------------------------------------------------------

def check_guest_to_backend():
    """guest TX -> Router.pump_once() -> Backend.from_guest()."""
    transport = FakeTransport()
    backend = RecordingBackend()
    router = ChannelRouter(transport, {CHANNEL: backend})

    transport.inject_guest_tx(CHANNEL, b"AT DT5551212\r")
    router.pump_once()

    assert bytes(backend.received) == b"AT DT5551212\r", (
        f"backend did not receive guest TX: got {bytes(backend.received)!r}"
    )
    # And nothing should have leaked back to the guest on this direction.
    assert transport.sent_to_guest(CHANNEL) == b"", (
        "guest->backend case delivered something back to the guest "
        "unexpectedly"
    )


def check_backend_to_guest():
    """Backend.to_guest() -> Router.pump_once() -> guest RX."""
    transport = FakeTransport()
    backend = CannedBackend(b"OK\r\n")
    router = ChannelRouter(transport, {CHANNEL: backend})

    router.pump_once()

    assert transport.sent_to_guest(CHANNEL) == b"OK\r\n", (
        f"guest did not receive backend's bytes: "
        f"got {transport.sent_to_guest(CHANNEL)!r}"
    )


def check_cat_roundtrip():
    """Full roundtrip through a REAL subprocess (`cat`): bytes injected
    as guest TX must come back out as guest RX unchanged, proving the
    router pumps both directions through an actual OS pipe, not just
    the in-memory fakes."""
    transport = FakeTransport()
    backend = ExecBackend(["cat"], use_pty=False)
    router = ChannelRouter(transport, {CHANNEL: backend})
    try:
        payload = b"hello from the guest, 1234567890\n"
        transport.inject_guest_tx(CHANNEL, payload)

        def delivered():
            router.pump_once()
            return transport.sent_to_guest(CHANNEL) == payload

        ok = _poll_until(delivered)
        assert ok, (
            f"cat roundtrip incomplete: got "
            f"{transport.sent_to_guest(CHANNEL)!r}, wanted {payload!r}"
        )
    finally:
        router.close()


def check_socket_transport():
    """SocketTransport against a stand-in for `fast_sdl --ssc-socket`: a
    listening Unix socket in this process. Bytes the fake emulator
    sends (guest TX) must reach the backend; bytes the backend answers
    must arrive at the fake emulator (guest RX). Round trip through a
    real LoopbackBackend and a real AF_UNIX socket -- the shape the live
    `tip` session uses, minus the 6502."""
    import socket
    import tempfile
    import threading
    from transport import SocketTransport
    from backends import LoopbackBackend

    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "ssc.sock")
    lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    lsock.bind(path)
    lsock.listen(1)
    accepted = {}

    def emu():
        c, _ = lsock.accept()
        accepted["c"] = c

    t = threading.Thread(target=emu, daemon=True)
    t.start()
    transport = SocketTransport(path)
    t.join(2.0)
    emu_side = accepted["c"]
    emu_side.setblocking(False)
    router = ChannelRouter(transport, {CHANNEL: LoopbackBackend()})
    try:
        payload = b"guest says hi over the socket\r"
        emu_side.sendall(payload)                 # the guest transmitted this
        got = bytearray()

        def echoed():
            router.pump_once()
            try:
                got.extend(emu_side.recv(4096))
            except BlockingIOError:
                pass
            return bytes(got) == payload

        ok = _poll_until(echoed)
        assert ok, f"socket roundtrip incomplete: got {bytes(got)!r}, wanted {payload!r}"
    finally:
        router.close()
        emu_side.close()
        lsock.close()
        os.unlink(path)
        os.rmdir(tmp)


CASES = [
    ("guest -> backend (TX direction)", check_guest_to_backend),
    ("backend -> guest (RX direction)", check_backend_to_guest),
    ("full roundtrip through exec(cat)", check_cat_roundtrip),
    ("socket transport roundtrip (fake fast_sdl listener)", check_socket_transport),
]


def run_cases(cases):
    """Run each (name, fn) case, print PASS/FAIL per case, return the
    list of failed names."""
    failed = []
    for name, fn in cases:
        try:
            fn()
        except AssertionError as e:
            print(f"  FAIL: {name}: {e}")
            failed.append(name)
        except Exception as e:
            print(f"  FAIL: {name}: unexpected {type(e).__name__}: {e}")
            failed.append(name)
        else:
            print(f"  PASS: {name}")
    return failed


# ---------------------------------------------------------------------
# Teeth demonstration: break ONE direction of pump_once, show the
# direction-specific assertions above correctly fail, then restore the
# real implementation and re-run clean. This is the "prove the teeth"
# step -- a test that can't be made to fail on broken code isn't
# proven to test anything.
# ---------------------------------------------------------------------

def _pump_once_drop_rx(self):
    """A deliberately-broken pump_once: still delivers guest->backend,
    but never delivers backend->guest. Mirrors a real bug shape (e.g.
    someone forgets the write_to_guest call after adding a second
    channel)."""
    moved = 0
    for channel_id, backend in self.channels.items():
        guest_tx = self.transport.read_from_guest(channel_id)
        if guest_tx:
            backend.from_guest(guest_tx)
            moved += len(guest_tx)
        backend.to_guest()  # drained and silently discarded -- the bug
    return moved


def demonstrate_teeth():
    print("\nTeeth demonstration: breaking the RX (backend->guest) "
          "direction of ChannelRouter.pump_once ...")
    original_pump_once = ChannelRouter.pump_once
    ChannelRouter.pump_once = _pump_once_drop_rx
    try:
        broken_failures = run_cases([
            ("backend -> guest (RX direction) [EXPECTED TO FAIL]",
             check_backend_to_guest),
            ("full roundtrip through exec(cat) [EXPECTED TO FAIL]",
             check_cat_roundtrip),
        ])
    finally:
        ChannelRouter.pump_once = original_pump_once

    if len(broken_failures) == 2:
        print("  teeth PASS: both RX-direction checks failed against "
              "the tampered router, as expected")
        teeth_ok = True
    else:
        print(f"  teeth FAIL: expected 2 failures under the tampered "
              f"router, saw {len(broken_failures)} "
              f"({broken_failures!r}) -- the test may not actually be "
              f"exercising the RX path")
        teeth_ok = False

    print("Restoring ChannelRouter.pump_once and re-running clean ...")
    assert ChannelRouter.pump_once is original_pump_once
    restored_failures = run_cases(CASES)
    if not restored_failures:
        print("  restore PASS: all cases pass again with the real "
              "pump_once")
    else:
        print(f"  restore FAIL: {restored_failures!r} still failing "
              f"after restore")

    return teeth_ok and not restored_failures


def main():
    print("serbridge router self-test")
    print("-- straight run --")
    failed = run_cases(CASES)

    teeth_ok = demonstrate_teeth()

    print()
    if not failed and teeth_ok:
        print("PASS: router routes bytes correctly in both directions, "
              "and the test suite was shown to have teeth")
        return 0

    print("FAIL:")
    if failed:
        print(f"  straight run failed: {failed!r}")
    if not teeth_ok:
        print("  teeth demonstration did not behave as expected")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
