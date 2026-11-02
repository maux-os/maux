#!/usr/bin/env python3
"""serbridge.py -- CLI entry point for the serial-bridge daemon.

Connects verilogapple's simulated Super Serial Card (one channel today)
to a host endpoint (a pty a human can `screen` into, or a spawned
process like a shell), via the MCP worker. See README.md for the
full picture; `--help` below is the quick reference.

Usage (tip IN -- a human gets a terminal on the emulated IIe's serial
line):
    python3 -m serbridge --channel ssc --backend pty

Usage (tip OUT -- the emulated IIe talks to a host shell):
    python3 -m serbridge --channel ssc --backend exec --exec /bin/sh

The router self-test (test_router.py) is the acceptance gate and needs
no emulator. This CLI's live path (daemon <-> a running mcp_worker_fast
<-> maux's in-guest serial driver) is a manual smoke test -- see
README.md's "Manual smoke test" section; maux's own serial driver is a
sibling slice still in progress, so the in-guest half can't be
exercised from here yet.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from router import ChannelRouter                                   # noqa: E402
from backends import PtyBackend, ExecBackend, LoopbackBackend         # noqa: E402
from transport import McpTransport, SocketTransport                                   # noqa: E402


def build_backend(args):
    if args.backend == "pty":
        return PtyBackend()
    if args.backend == "exec":
        return ExecBackend(args.exec_cmd or "/bin/sh", use_pty=not args.exec_pipes,
                           term=args.term, cols=args.cols, rows=args.rows,
                           eight_bit=args.eight_bit)
    if args.backend == "loopback":
        return LoopbackBackend()
    if args.backend == "tcp":
        from backends import TcpBackend
        if not args.tcp:
            raise SystemExit("--backend tcp requires --tcp HOST:PORT")
        host, _, port = args.tcp.rpartition(":")
        return TcpBackend(host, int(port))
    if args.backend == "listen":
        from backends import ListenBackend
        if args.listen is None:
            raise SystemExit("--backend listen requires --listen PORT")
        return ListenBackend(args.listen)
    raise SystemExit(f"unknown backend {args.backend!r}")


def build_parser():
    p = argparse.ArgumentParser(
        prog="serbridge",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--channel", default="ssc",
        help="channel id to bridge (default: ssc -- the one Super "
             "Serial Card channel the router/transport know about "
             "today; a future multi-channel card adds more ids here)")
    p.add_argument(
        "--backend", choices=["pty", "exec", "loopback", "tcp", "listen"],
        default="pty",
        help="host endpoint to wire this channel to: "
             "pty = allocate a PTY and print its slave path (tip IN, "
             "e.g. `screen /dev/ttysNNN`); "
             "exec = spawn a host process (see --exec) and wire its "
             "stdio (tip OUT); "
             "loopback = echo guest TX straight back as guest RX, no "
             "host resources (manual smoke-test only); "
             "tcp/listen = stubs for a future slice (socket "
             "service backends) -- constructing one raises "
             "NotImplementedError with the TODO. (default: pty)")
    p.add_argument(
        "--pty", action="store_const", dest="backend", const="pty",
        help="shorthand for --backend pty")
    p.add_argument(
        "--exec", dest="exec_cmd", nargs="?", const="/bin/sh", default=None,
        metavar="CMD",
        help="shorthand for --backend exec, optionally naming the "
             "command to spawn (default when given bare: /bin/sh). "
             "Passing --exec alone also selects the exec backend.")
    p.add_argument(
        "--tcp", metavar="HOST:PORT", default=None,
        help="(stub, slice 4+) host:port for --backend tcp")
    p.add_argument(
        "--listen", metavar="PORT", type=int, default=None,
        help="(stub, slice 4+) port to accept on for --backend listen")
    p.add_argument(
        "--supervisor", default=None,
        help="path to verilogapple's mcp_supervisor binary for the MCP "
             "transport (default: scripts/mcp_drive.py's SUPERVISOR, "
             "overridable there via $MAUX_SUPERVISOR)")
    p.add_argument(
        "--roms-dir", default=None,
        help="ROMs directory forwarded to the MCP worker as "
             "$VERILOGAPPLE_ROMS (default: scripts/mcp_drive.py's "
             "ROMS_DIR)")
    p.add_argument(
        "--poll-interval", type=float, default=0.02,
        help="seconds between router pump rounds (default: 0.02)")
    p.add_argument(
        "--transport", choices=["mcp", "socket"], default=None,
        help="how the router reaches the emulator's serial line: "
             "'mcp' = McpTransport, spawning a headless mcp_worker_fast "
             "through scripts/mcp_drive.py's MCPClient (gates, scripts); "
             "'socket' = SocketTransport, connecting to the Unix stream "
             "socket a running `fast_sdl --ssc --ssc-socket PATH` "
             "listens on (a human at the window). (default: socket if "
             "--socket is given, else mcp)")
    p.add_argument(
        "--socket", metavar="PATH", default=None,
        help="path of fast_sdl's --ssc-socket (implies --transport socket)")
    p.add_argument(
        "--term", default="vt102",
        help="TERM exported to the --exec command (default: vt102, the "
             "maux console's target; docs/CONSOLE-VT102.md)")
    p.add_argument(
        "--cols", type=int, default=80,
        help="pty window width handed to the --exec command (default 80; "
             "pass 40 for a 40-column maux console)")
    p.add_argument(
        "--rows", type=int, default=24,
        help="pty window height for the --exec command (default 24)")
    p.add_argument(
        "--8bit", dest="eight_bit", action="store_true",
        help="pass bytes >= $80 from the --exec command through raw; by "
             "default each UTF-8 code point the 7-bit VT102 cannot show is "
             "folded to one '?' (the console discards bit 7 as parity, so "
             "an em-dash would otherwise paint as 'b')")
    p.add_argument(
        "--exec-pipes", action="store_true",
        help="run the --exec command on pipes instead of a pty (no job "
             "control, no screen programs; the router self-test's shape)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    if args.exec_cmd is not None and args.backend == "pty":
        # --exec implies the exec backend even if --backend wasn't
        # explicitly set to it (argparse default would otherwise win).
        args.backend = "exec"

    backend = build_backend(args)

    transport_kind = args.transport or ("socket" if args.socket else "mcp")
    if transport_kind == "mcp":
        transport = McpTransport(supervisor=args.supervisor, roms_dir=args.roms_dir)
    elif transport_kind == "socket":
        if not args.socket:
            raise SystemExit("--transport socket needs --socket PATH")
        transport = SocketTransport(args.socket)
    else:
        raise SystemExit(f"unknown transport {transport_kind!r}")

    router = ChannelRouter(transport, {args.channel: backend})
    print(f"serbridge: routing channel {args.channel!r} "
          f"<-> {args.backend} backend, polling every "
          f"{args.poll_interval}s (Ctrl-C to stop)")
    try:
        router.run(poll_interval=args.poll_interval)
    finally:
        router.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
