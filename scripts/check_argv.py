#!/usr/bin/env python3
"""check_argv.py -- ARG_MAX byte-budget acceptance gate (docs/LIMITS.md).

The case table here MUST stay in step with src/test/argvtestb.s's
CASE_N/CASE_L/CASE_E; that file's header explains what each case proves.

The load-bearing pair is cases 2 and 3: an argv of exactly ARG_MAX bytes
must arrive WHOLE, and an argv of exactly ARG_MAX+1 must come back as
ERR_2BIG rather than as a successful spawn with a short argv. A gate that
checked only the first would pass against the truncating code this
replaced -- which is precisely how that truncation survived unnoticed
from task #13 until sh grew globbing.

Cases 7 and 8 are the same pair again for the SHARED budget
(docs/SYSCALL.md item 13c): ARG_MAX now covers argv's strings AND the
environment's, so the ceiling case splits its 1280 bytes between the two
and the overflow case adds its one byte to the ENVIRONMENT -- one layer
past where argv's own check can see it, which is the shape
learning:01M07V2D0T25FYD6ASCMPJYNWQ says a count-shaped cap hides in.

Statuses: the child reports ARGC, with bit 7 SET when it also verified a
non-empty environment ($93 == 19 args + an environment). $EE is any
layout violation. See src/test/argvtestb.s's SIMG_VERIFY.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402


R_SPWERR = 0x1100
R_STATUS = 0x1110
R_DONE = 0x11F0
R_ERR = 0x11F1

ERR_2BIG = 0xE7

# (label, expected spawn errno, expected child exit status)
CASES = [
    ("3 short args",                     0x00, 3),
    ("one 100-byte arg (was cut at 63)", 0x00, 1),
    ("20 x 64B = exactly ARG_MAX",       0x00, 20),
    ("ARG_MAX + 1 byte",                 ERR_2BIG, 0),
    ("127 args (pointer array full)",    0x00, 127),
    ("128 args (one pointer past)",      ERR_2BIG, 0),
    ("3 short args again (no bank leak)", 0x00, 3),
    ("19 args + 1 env = exactly ARG_MAX", 0x00, 0x93),
    ("shared ARG_MAX + 1, in the env",    ERR_2BIG, 0),
    ("3 short args again (no env leak)",  0x00, 3),
]


def peek(client, addr, count=1, bank="main", aux_bank=None):
    args = {"addr": addr, "count": count, "bank": bank}
    if aux_bank is not None:
        args["aux_bank"] = aux_bank
    return client.call_tool("peek", args)["bytes"]


def fail(msg):
    print(f"[check-argv] FAIL: {msg}", file=sys.stderr)
    return 1


def main():
    disk_path = sys.argv[1] if len(sys.argv) > 1 else "build/argvtest.po"
    if not os.path.exists(disk_path):
        return fail(f"{disk_path} not found")

    env = dict(os.environ)
    env["VERILOGAPPLE_ROMS"] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool("reset", {"backend": "fast"})
        print(f"[check-argv] reset -> {r}", file=sys.stderr)
        r = client.call_tool("mount_disk", {"path": os.path.abspath(disk_path)})
        print(f"[check-argv] mount_disk -> {r}", file=sys.stderr)
        if r.get("ok") is False:
            return fail(f"mount_disk failed: {r}")

        # The byte-ceiling cases copy ~1.3KB of argv a byte at a time through
        # copyin to MEASURE it, then again in BankCopy chunks to place it, so
        # this gate is slower than check-process for the same case count.
        done = err = 0
        for i in range(200):
            client.call_tool("step", {"cycles": 200_000})
            done, err = peek(client, R_DONE, 2, bank="aux", aux_bank=1)
            if done:
                print(f"[check-argv] done after {(i + 1) * 200000} cycles")
                break

        if done != 0xAA:
            screen = client.call_tool("screen_text", {})["main"][0]
            return fail(f"done marker ${done:02X}, err=${err:02X}, screen={screen!r}")
        if err != 0:
            return fail(f"parent recorded a wait error ${err:02X}")

        errs = peek(client, R_SPWERR, len(CASES), bank="aux", aux_bank=1)
        stats = peek(client, R_STATUS, len(CASES), bank="aux", aux_bank=1)
        print(f"[check-argv] spawn errnos: {[hex(x) for x in errs]}")
        print(f"[check-argv] exit statuses: {[hex(x) for x in stats]}")

        ok = True
        for i, (label, want_err, want_status) in enumerate(CASES):
            got_err, got_status = errs[i], stats[i]
            if got_err != want_err or got_status != want_status:
                detail = ""
                if want_err == 0 and got_err == 0 and got_status == 0xEE:
                    detail = ("  (child ran but its argv was malformed: a "
                              "truncated argument or a pointer/string "
                              "mismatch -- see SIMG_VERIFY)")
                elif want_err == ERR_2BIG and got_err == 0:
                    detail = ("  (spawn SUCCEEDED past the ceiling -- this is "
                              "the silent-truncation failure the gate exists "
                              "for)")
                print(f"[check-argv] FAIL: case {i} ({label}): "
                      f"errno ${got_err:02X} status ${got_status:02X}, "
                      f"want errno ${want_err:02X} status ${want_status:02X}"
                      f"{detail}", file=sys.stderr)
                ok = False
            else:
                print(f"[check-argv] PASS: case {i} ({label}): "
                      f"errno ${got_err:02X}, status ${got_status:02X}")

        return 0 if ok else 1
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
