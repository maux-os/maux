"""serbridge -- host-side serial-bridge daemon for maux's simulated Super
Serial Card (slice 3).

Three layers, kept strictly separate so a future quad-channel/MCU
coprocessor card is "more channels + a different transport", not a
rewrite:

  router.py     -- the ChannelRouter core: channel id -> Backend table,
                   pumps bytes both directions against a Transport.
                   Depends only on the Backend/Transport interfaces.
  backends.py   -- pluggable per-channel endpoints (pty, exec, tcp/listen
                   stubs). Each implements to_guest()/from_guest().
  transport.py  -- how the router reaches the emulator's serial line.
                   McpTransport drives verilogapple's mcp_worker_fast
                   over scripts/mcp_drive.py's MCPClient.

See README.md for usage. See test_router.py for the no-emulator-needed
self-test (the acceptance gate for this slice).
"""
