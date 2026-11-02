"""kcold_hook/sitecustomize.py -- arm verilogapple's mem_profile inside
EVERY gate that drives the emulator through scripts/mcp_drive.MCPClient.

Not a gate.  Python imports a module named `sitecustomize` from
sys.path at interpreter start, so putting this directory on PYTHONPATH
instruments every python3 the gates spawn without touching the gates.
It does nothing unless KCOLD_DIR is set.  scripts/kcold_gates.py is the
driver (`run`) and the reader (`report`); docs/KLEDGER-NOTES.md sec 8
is the method and the first result.

What it does, per MCPClient: on the FIRST `reset` it calls
`mem_profile start` (the map persists across later resets, so one dump
is the union over the whole gate; it fails silently on the rtl backend,
which has no mem_profile); on `close`, and at exit for clients never
closed, it writes KCOLD_DIR/map-<pid>-<n>.json with the READ map
(untouched ranges), the gate name from KCOLD_GATE, the mounted image
paths and 256 bytes of main RAM at $2000 and at $9400 so the reader can
keep only the maps of ONE kernel (a bye tenant or a raw-boot kernel
in the same gate run is a different image).  It never raises into the
gate: an instrument failure goes to KCOLD_DIR/errors.log.
"""
import atexit
import json
import os
import re
import sys
import weakref

_DIR = os.environ.get('KCOLD_DIR')
if _DIR:
    _md = None
    try:
        sys.path.insert(0, os.path.join(
            os.environ.get('MAUX_ROOT', os.getcwd()), 'scripts'))
        import mcp_drive as _md
    except Exception:
        _md = None
    if _md is not None:
        _live = weakref.WeakSet()
        _orig_call = _md.MCPClient.call_tool
        _orig_close = _md.MCPClient.close
        _n = [0]

        def _call(self, name, arguments=None):
            r = _orig_call(self, name, arguments)
            if name == 'reset' and not getattr(self, '_kc_armed', False):
                try:
                    a = _orig_call(self, 'mem_profile', {'action': 'start'})
                    self._kc_armed = bool(a.get('ok'))
                    self._kc_backend = (arguments or {}).get('backend')
                    _live.add(self)
                except Exception:
                    self._kc_armed = False
            if name == 'type' and getattr(self, '_kc_armed', False):
                # a person (e2e_term) types one key per call: keep the
                # tail, and dump when Enter lands right after `bye`
                self._kc_tail = (getattr(self, '_kc_tail', '') + (
                    (arguments or {}).get('text') or ''))[-24:]
                if re.search(r'(^|[\s;|&(])bye\s*(\r|\\r)$',
                             self._kc_tail, re.I):
                    _dump(self, 'prebye')
                    self._kc_tail = ''
            if name == 'mount_disk':
                self._kc_mounts = getattr(self, '_kc_mounts', []) + [
                    (arguments or {}).get('path')]
            return r

        def _dump(self, phase=None):
            if not getattr(self, '_kc_armed', False) or getattr(
                    self, '_kc_dumped', False):
                return
            if phase is None:
                self._kc_dumped = True
            try:
                rep = _orig_call(self, 'mem_profile', {
                    'action': 'report', 'mode': 'read',
                    'max_ranges': 100000})
                ids = {}
                for addr in (0x2000, 0x9400):
                    p = _orig_call(self, 'peek', {'addr': addr, 'count': 256,
                                                  'bank': 'main'})
                    ids['%04X' % addr] = p.get('bytes')
                _n[0] += 1
                out = os.path.join(_DIR, 'map-%d-%d.json' % (os.getpid(),
                                                             _n[0]))
                with open(out, 'w') as fh:
                    json.dump({'gate': os.environ.get('KCOLD_GATE'),
                               'argv': sys.argv, 'cwd': os.getcwd(),
                               'backend': getattr(self, '_kc_backend', None),
                               'mounts': getattr(self, '_kc_mounts', []),
                               'phase': phase,
                               'ids': ids, 'report': rep}, fh)
            except Exception as e:  # never break a gate
                try:
                    with open(os.path.join(_DIR, 'errors.log'), 'a') as fh:
                        fh.write('%r %r\n' % (sys.argv, e))
                except Exception:
                    pass

        def _close(self):
            _dump(self)
            return _orig_close(self)

        def _exit():
            for c in list(_live):
                try:
                    if c.proc.poll() is None:
                        _dump(c)
                except Exception:
                    pass

        _md.MCPClient.call_tool = _call
        _md.MCPClient.close = _close
        atexit.register(_exit)
