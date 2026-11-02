#!/usr/bin/env python3
"""teeth_rig.py -- the sabotage runner behind the oracle-rig canary of
check-shseq, check-shexecloop, check-shmlquote and check-shfd (SH-G21
F4, docs/SH-G21-NOTES.md sec 6/7). NOT a gate and in no sweep.

Each gate's script-row oracle runs a nested `sh ./m` as a shell
function. That function must run the host shell UNDER TEST; the old
shim ran dash under both, so bash 5 was never asked. Every gate now
runs a host-only canary first (rig_selftest). This runner (on
scripts/teeth_lib.py, HYG-4) puts the shim back in the file that holds
it, runs the gate, and requires it RED on the failure row `RIG` before
any emulator boots (a second or so each), then restores the captured
bytes. The sabotage text must match exactly once or the runner FAILS.
Only host scripts change: no build, sh.bin is untouched by construction.
check-shfd/-shseq/... print the canary only as a failure bullet. Exit
status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2 runner
broken).

  python3 scripts/teeth_rig.py            # all
  python3 scripts/teeth_rig.py TR3        # by name prefix
  python3 scripts/teeth_rig.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

MQ = 'scripts/check_shmlquote.py'
FD = 'scripts/check_shfd.py'
MQ_OLD = "fh.write('sh() { %s \"$@\"; }\\n' % shell)"
MQ_NEW = "fh.write('sh() { %s \"$@\"; }\\n' % F.DASH)"
FD_OLD = "fh.write('sh() { %s \"$@\"; }\\n' % shell)"
FD_NEW = "fh.write('sh() { %s \"$@\"; }\\n' % DASH)"

# (name, gate command, file, old, new)
SPECS = [
    ('TR1 check-shseq: the dash shim is back (shared M.host_run)',
     'python3 scripts/check_shseq.py', MQ, MQ_OLD, MQ_NEW),
    ('TR2 check-shexecloop: the dash shim is back (shared M.host_run)',
     'python3 scripts/check_shexecloop.py', MQ, MQ_OLD, MQ_NEW),
    ('TR3 check-shmlquote: the dash shim is back',
     'python3 scripts/check_shmlquote.py', MQ, MQ_OLD, MQ_NEW),
    ('TR4 check-shfd: the dash shim is back (its own host_run)',
     'python3 scripts/check_shfd.py', FD, FD_OLD, FD_NEW),
]

# (name, gate command, file, old, new)
SPECS = [
    ('TR1 check-shseq: the dash shim is back (shared M.host_run)',
     'python3 scripts/check_shseq.py', MQ, MQ_OLD, MQ_NEW),
    ('TR2 check-shexecloop: the dash shim is back (shared M.host_run)',
     'python3 scripts/check_shexecloop.py', MQ, MQ_OLD, MQ_NEW),
    ('TR3 check-shmlquote: the dash shim is back',
     'python3 scripts/check_shmlquote.py', MQ, MQ_OLD, MQ_NEW),
    ('TR4 check-shfd: the dash shim is back (its own host_run)',
     'python3 scripts/check_shfd.py', FD, FD_OLD, FD_NEW),
]


T.main('rig', [
    T.Tooth(name, edits=[(fn, old, new)], witness=T.SourceOnly(),
            prep=T.NoBuild(), artifacts=(), checks=[T.Check(
                cmd, 'aggregate', T.Aggregate(
                    r'^\[%s\] FAIL: RIG selftest' % T.tag_of(cmd),
                    'the canary is a single FAIL line, before any row'))])
    for name, cmd, fn, old, new in SPECS])
