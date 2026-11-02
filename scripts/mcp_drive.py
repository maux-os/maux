#!/usr/bin/env python3
"""mcp_drive.py -- headless stdio MCP client that boots build/maux.po under
verilogapple's mcp_supervisor and asserts a needle string appears on the
40-col text screen. Drives the hard gate for maux task #1 (`make
check-boot`): both the fast and rtl backends must show "MAUX ALIVE".

Python stdlib only, per the task contract.

Protocol notes (verified by reading ~/src/verilogapple/sim/mcp/mcp_supervisor.cpp
and mcp_server.cpp -- no MCP SDK, no Content-Length framing):
  - Transport is newline-delimited JSON-RPC 2.0 on stdin/stdout: exactly one
    JSON object per line, both directions. No LSP-style headers.
  - Handshake: send "initialize", read its response, then send the
    "notifications/initialized" notification (no id -> no response).
  - "tools/call" results are DOUBLE-ENCODED: the JSON-RPC "result" is
    {"content": [{"type": "text", "text": "<json>"}]}; the inner "text" is
    itself a JSON document holding the tool's actual return value (e.g.
    {"ok": true, ...} for reset/mount_disk, {"main": [...], ...} for
    screen_text). Must json.loads() twice.
  - mcp_supervisor forks the real worker (Vapple2e_sim_top) into its own
    cwd (<supervisor_dir>/../../top), NOT the caller's cwd -- so any
    filesystem path handed to a tool (mount_disk's "path") must be made
    absolute before sending, or it resolves against the wrong directory.

Library handle: learning:01KWF4QBFJ8EJWK21JVP16VEM7 (verilogapple MCP tool
surface: reset/mount_disk/step/screen_text semantics) and the cold-read
amendment in docs/TASKS.md #1 (step's cycle-unit gotcha: fast = 1 CPU bus
cycle per unit, rtl = 1 14M tick per unit, ~14 ticks per CPU cycle).
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_race as GR                                       # noqa: E402

# Overridable so the SAME gate scripts run on a box whose emulator lives
# elsewhere (verilogapple#18 / spec-11: /opt/verilogapple on the Linux
# box, with VERILOGAPPLE_ROMS set box-wide in /etc/environment). The
# defaults are the sibling checkout under ~/src. SUPERVISOR stays a
# single path: gates spawn it locally wherever they run -- the box runs
# the suite itself rather than driving a remote worker, because 70
# gates mount images by a path the WORKER must see and 15 read the
# mutated image back on the host.
VERILOGAPPLE = os.path.expanduser(os.environ.get(
    "VERILOGAPPLE", "~/src/verilogapple"))
SUPERVISOR = os.environ.get(
    "MAUX_SUPERVISOR",
    os.path.join(VERILOGAPPLE, "sim/mcp/obj_dir/mcp_supervisor"))
ROMS_DIR = os.environ.get(
    "VERILOGAPPLE_ROMS",
    os.path.join(VERILOGAPPLE, "sim/roms"))

# The build tier (docs/DEPENDENCIES.md) has no emulator by design. A gate
# run there used to find an UNLOCKED ~/src/verilogapple if the host had one
# and run against it; refuse by name instead (docs/DEPS-TIER-NOTES.md P4).


def refuse_in_build_tier():
    """Called when a supervisor is about to be SPAWNED, not on import: the
    build tier legitimately imports this module (build_full_image reaches it
    through check_librel) and never starts an emulator."""
    if os.environ.get("MAUX_TIER") == "build":
        raise SystemExit(
            "mcp_drive: this tree was bootstrapped with TIER=build, which has "
            "no verilogapple, so an emulator gate cannot run here. Provision "
            "the test tier (make bootstrap-deps ROM_DIR=... into a new "
            "DEPS_ROOT, docs/DEPENDENCIES.md).")

# rtl's step unit is a 14.318 MHz tick; the CPU advances roughly once every
# 14 of those (14.318 MHz / ~1.023 MHz). fast's step unit IS a CPU cycle.
# learning:01KWF4QBFJ8EJWK21JVP16VEM7 / docs/TASKS.md #1 cold-read amendment.
RTL_TICKS_PER_CPU_CYCLE = 14


#: Power-on RAM patterns (learning:01M5BJPRFJKM856GCNY670B725): AppleWin's
#: and Apple2TS's models. Each tiles a 64K bank.
DIRTY_FILLS = {
    "zero": bytes([0x00]),
    "ff": bytes([0xFF]),
    "ffff0000": bytes([0xFF, 0xFF, 0x00, 0x00]),
}


class MCPError(RuntimeError):
    pass


class MCPClient:
    """Minimal newline-delimited JSON-RPC 2.0 client over a child process's
    stdio. Spawns mcp_supervisor directly (no MCP SDK) -- stdlib subprocess
    + json only, per the task's Python-stdlib-only constraint."""

    def __init__(self, cmd, env):
        refuse_in_build_tier()
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,  # let the supervisor's stderr pass through for debugging
            env=env,
            text=True,
            bufsize=1,  # line-buffered
        )
        self._next_id = 0
        self._gr_line = ['']       # MAUX_GATE_RACE: the line being typed
        # a gate that must see every cycle (check-wake's trace ring is
        # 1M rows) takes the late lag itself: a callable(cycles)
        self.gr_lag = None
        self.gr_cycles = 0         # guest cycles stepped through call_tool

    def _send(self, obj):
        line = json.dumps(obj)
        assert self.proc.stdin is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _recv(self):
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if not line:
            rc = self.proc.poll()
            raise MCPError(
                f"mcp_supervisor closed stdout unexpectedly (exit code {rc})"
            )
        return json.loads(line)

    def request(self, method, params=None):
        self._next_id += 1
        req = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            req["params"] = params
        self._send(req)
        resp = self._recv()
        if "error" in resp:
            raise MCPError(f"{method} failed: {resp['error']}")
        return resp["result"]

    def notify(self, method, params=None):
        note = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            note["params"] = params
        self._send(note)

    def initialize(self):
        self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "maux-mcp-drive", "version": "0.1.0"},
            },
        )
        self.notify("notifications/initialized")

    def require_tools(self, *names):
        """Fail early, and by name, when the emulator build lacks a tool.

        maux's gates depend on MCP tools that live on DIFFERENT verilogapple
        branches: `eject_disk` (check-rel/check-merlin/check-dual) is on
        milestone/smartport-n-drive, `ultraterm_state` (check-ultraterm,
        check-play80) on milestone/ultraterm-state. Rebuilding the worker
        from a branch missing either one turns a gate into an opaque
        `unknown tool: X` traceback three layers down -- which is exactly
        how three gates broke on 2026-08-17. See docs/TOOLCHAIN.md.
        """
        have = {t.get('name') for t in
                self.request('tools/list').get('tools', [])}
        missing = [n for n in names if n not in have]
        if missing:
            raise MCPError(
                f"the verilogapple MCP worker is missing {', '.join(missing)}. "
                f"It was built from a branch that lacks these tools -- see "
                f"docs/TOOLCHAIN.md for which branch maux's gates need.")

    def call_tool(self, name, arguments=None):
        result = self.request(
            "tools/call", {"name": name, "arguments": arguments or {}}
        )
        # Double-encoded: result.content[0].text is itself a JSON document.
        text = result["content"][0]["text"]
        out = json.loads(text)
        if name == "reset" and os.environ.get("MAUX_DIRTY_FILL"):
            self._dirty_after_reset(arguments or {}, out)
        if name == "step":
            self.gr_cycles += (arguments or {}).get("cycles", 0)
        if name == "type" and GR.MODE == "late":
            lag = GR.late_lag(GR.armed_lines(
                self._gr_line, (arguments or {}).get("text", "")))
            if lag and self.gr_lag:
                self.gr_lag(lag)
            elif lag:
                self.request("tools/call", {
                    "name": "step", "arguments": {"cycles": lag}})
                self.gr_cycles += lag
        return out

    def _dirty_after_reset(self, args, out):
        """MAUX_DIRTY_FILL=ff|ffff0000 runs ANY gate on dirty RAM: every
        `reset` is followed by a fill of main and every aux bank the card
        has, before the gate's own first poke (docs/KFIX11.md). The
        emulator zero-fills by default, which hides every
        read-before-write in the kernel."""
        if out.get("ok") is False:
            return
        kind = args.get("aux", "ramworks")
        # an omitted aux_banks is the tool's own default, 16 (reset's
        # `args.value("aux_banks", 16)`); a 64K aux card is one bank
        banks = {"ramworks": args.get("aux_banks", 16), "ext64k": 1,
                 "80col": 1}.get(kind, 0)
        self.fill_ram(DIRTY_FILLS[os.environ["MAUX_DIRTY_FILL"]], banks)

    def fill_ram(self, pat, banks):
        """Poke `pat` tiled over every byte of main and of aux banks
        0..banks-1, then read corner cells back. One 64K poke per bank:
        the `bytes` array wraps the 16-bit address and the write is to the
        raw DRAM array with no MMU remap, so main's $C000-$CFFF is
        language-card bank 2 and $D000-$FFFF bank 1. A poke that failed,
        or a fill that did not land, would make a dirty run a zero run in
        disguise (the 2026-10-20 bisection trap), so both are errors."""
        page = list(pat * (65536 // len(pat)))

        def poke(**kw):
            r = self.call_tool("poke", dict(addr=0, bytes=page, **kw))
            if r.get("ok") is False:
                raise MCPError(f"dirty fill: poke {kw} failed: {r}")
        poke(bank="main")
        for b in range(banks):
            poke(bank="aux", aux_bank=b)
        corners = [("main", 0, 0x0200), ("main", 0, 0xC000),
                   ("main", 0, 0xFFF0)]
        if banks:
            corners += [("aux", 0, 0x6040), ("aux", banks - 1, 0xFFF0)]
        for bank, ab, addr in corners:
            want = [pat[(addr + i) % len(pat)] for i in range(4)]
            got = self.call_tool("peek", {
                "addr": addr, "count": 4, "bank": bank,
                "aux_bank": ab})["bytes"]
            if got != want:
                raise MCPError(f"dirty fill did not land: {bank}[{ab}] "
                               f"${addr:04X} wanted {want}, got {got}")

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


def boot_and_check(disk_path, backend, needle, chunk_cpu_cycles, max_cpu_cycles,
                    verbose=True, aux_banks=None):
    """Reset -> mount -> step in chunks, polling screen_text, until the
    needle appears or max_cpu_cycles (in CPU-cycle terms, converted per
    backend) is exhausted. Polling adaptively (rather than guessing one
    fixed cycle count) avoids both under-stepping (miss the boot) and
    grossly over-stepping (costly on rtl, ~1000x slower wall clock than
    fast -- see docs/TASKS.md #1 cold-read amendment).

    aux_banks: optional int forwarded to the `reset` tool's aux_banks
    param (verilogapple default is 16 = 1MB RamWorks if omitted). Added
    for task #5's `check-probe` gate, which needs to prove the bank-probe
    allocator's free-bank count tracks a DIFFERENT configured card size,
    not just the default -- see docs/TASKS.md #5 and scripts/check_probe.py.
    """
    env = dict(os.environ)
    env["VERILOGAPPLE_ROMS"] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()

        reset_args = {"backend": backend}
        if aux_banks is not None:
            reset_args["aux_banks"] = aux_banks
        r = client.call_tool("reset", reset_args)
        if verbose:
            print(f"[{backend}] reset -> {r}", file=sys.stderr)
        if r.get("backend") != backend:
            raise MCPError(f"reset did not select backend {backend!r}: {r}")

        abs_disk_path = os.path.abspath(disk_path)
        r = client.call_tool("mount_disk", {"path": abs_disk_path})
        if verbose:
            print(f"[{backend}] mount_disk -> {r}", file=sys.stderr)
        if r.get("ok") is False:
            raise MCPError(f"mount_disk failed: {r}")

        ticks_per_cpu_cycle = RTL_TICKS_PER_CPU_CYCLE if backend == "rtl" else 1
        chunk = chunk_cpu_cycles * ticks_per_cpu_cycle
        max_total = max_cpu_cycles * ticks_per_cpu_cycle

        total = 0
        rows = []
        while total < max_total:
            client.call_tool("step", {"cycles": chunk})
            total += chunk
            st = client.call_tool("screen_text", {})
            rows = st.get("main", [])
            if any(needle in row for row in rows):
                return True, rows, total
            if verbose:
                print(f"[{backend}] stepped {total} step-units, no match yet", file=sys.stderr)

        return False, rows, total
    finally:
        client.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--backend", required=True, choices=["fast", "rtl"])
    ap.add_argument("--disk", required=True, help="path to the .po image to mount")
    ap.add_argument("--needle", default="MAUX ALIVE")
    ap.add_argument(
        "--chunk-cycles",
        type=int,
        default=200_000,
        help="CPU cycles to step per poll (converted to rtl's tick unit internally)",
    )
    ap.add_argument(
        "--max-cycles",
        type=int,
        default=4_000_000,
        help="CPU-cycle budget before giving up (converted per backend)",
    )
    ap.add_argument(
        "--aux-banks",
        type=int,
        default=None,
        help="forwarded to reset's aux_banks param (default: omit, "
             "verilogapple defaults to 16)",
    )
    args = ap.parse_args()

    if not os.path.exists(SUPERVISOR):
        print(
            f"error: mcp_supervisor not found at {SUPERVISOR}\n"
            f"build it with: make -C {VERILOGAPPLE} mcp",
            file=sys.stderr,
        )
        return 2
    if not os.path.exists(args.disk):
        print(f"error: disk image not found: {args.disk}", file=sys.stderr)
        return 2

    found, rows, total = boot_and_check(
        args.disk, args.backend, args.needle, args.chunk_cycles, args.max_cycles,
        aux_banks=args.aux_banks,
    )

    print(f"[{args.backend}] screen_text after {total} step-units:")
    for row in rows:
        stripped = row.rstrip()
        if stripped:
            print(f"  {stripped!r}")

    if found:
        print(f"[{args.backend}] PASS: found {args.needle!r}")
        return 0

    print(f"[{args.backend}] FAIL: {args.needle!r} not found within budget", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
