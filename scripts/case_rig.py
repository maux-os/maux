#!/usr/bin/env python3
"""case_rig.py -- shared emulator rig for the GS/OS case-flag work
(docs/PRODOS-CASE.md): boots a copy of build/play.po (optionally with
a2til-staged files, optionally a second SmartPort volume), types shell
lines, and exposes peek/regs.  Used by scripts/measure_case.py (the
measurements) and scripts/check_ls_case.py (the gate).  ASCII only.
"""
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
LISTING = os.path.join(BUILD, 'MAUXPLAY.SYSTEM_Output.txt')


def sym(name):
    """Address of `name` from the kernel listing.

    The symbol table (`NAME = value`) wins: a cell homed by an `equ`
    chain (inc/mm.kbss.equ) has the PC of its equ line in the address
    column, which is NOT its address (KSPACE2).  Falls back to the
    first listing row for a name the table does not carry."""
    from textaudit import parse_num
    tab = re.compile(r'^\s*%s\s*=\s*(\S+)\s*$' % re.escape(name))
    for line in open(LISTING, errors='replace'):
        m = tab.match(line)
        if m:
            return parse_num(m.group(1))
    pat = re.compile(r'\|\s*00/([0-9A-F]{4})\b[^|]*\|\s*%s\b' % re.escape(name))
    for line in open(LISTING, errors='replace'):
        m = pat.search(line)
        if m:
            return int(m.group(1), 16)
    raise KeyError(name)


class Rig:
    def __init__(self, tmp, second=True, stage=None):
        self.a = os.path.join(tmp, 'a.po')
        shutil.copy(os.path.join(BUILD, 'play.po'), self.a)
        if stage:
            vol = prodos.Volume(self.a)
            try:
                stage(vol)
            finally:
                vol.close()
        self.b = None
        if second:
            self.b = os.path.join(tmp, 'b.po')
            prodos.create(self.b, name='SECOND', blocks=800)
        env = dict(os.environ)
        env['VERILOGAPPLE_ROMS'] = ROMS_DIR
        self.c = MCPClient([SUPERVISOR], env)
        self.c.initialize()
        self.c.call_tool('reset', {'backend': 'fast'})
        self.c.call_tool('mount_disk', {'path': self.a})
        if self.b:
            self.c.call_tool('mount_disk', {'path': self.b})
        self.c.call_tool('reset', {'backend': 'fast'})
        self.c.call_tool('step', {'cycles': 30_000_000})

    def line(self, text, cycles=12_000_000):
        self.c.call_tool('type', {'text': text + '\n'})
        self.c.call_tool('step', {'cycles': cycles})

    def peek(self, addr, n=1):
        return self.c.call_tool('peek', {'addr': addr, 'count': n})['bytes']

    def screen(self):
        return self.c.call_tool('screen_text', {})['merged']

    def close(self):
        self.c.close()
