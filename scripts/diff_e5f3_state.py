#!/usr/bin/env python3
"""diff_e5f3_state.py -- compact diff table over build/e5f3_working.json
vs build/e5f3_direct.json (scripts/capture_e5f3_state.py), per
docs/AS-DESIGN.md section 11's state-diff technique."""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')


def load(name):
    with open(os.path.join(BUILD, name)) as fh:
        return json.load(fh)


def main():
    w = load('e5f3_working.json')
    d = load('e5f3_direct.json')
    print(f"working: {w['label']}")
    print(f"direct:  {d['label']}")
    print()

    print('-- softswitches --')
    sw_w, sw_d = w['softswitches'], d['softswitches']
    keys = sorted(set(sw_w) | set(sw_d))
    for k in keys:
        vw, vd = sw_w.get(k), sw_d.get(k)
        mark = '  ' if vw == vd else '**'
        print(f'{mark} {k:<16} working={vw!r:<8} direct={vd!r}')
    print()

    print('-- regs --')
    r_w, r_d = w['regs'], d['regs']
    keys = sorted(set(r_w) | set(r_d))
    for k in keys:
        vw, vd = r_w.get(k), r_d.get(k)
        mark = '  ' if vw == vd else '**'
        print(f'{mark} {k:<8} working={vw!r:<8} direct={vd!r}')
    print()

    for name in ('zp', 'e0xx', 'page3'):
        rw = w['ranges'][name]
        rd = d['ranges'][name]
        bw = rw['bytes']
        bd = rd['bytes']
        addr0 = rw['addr']
        print(f"-- {name} (${addr0:04X}-${addr0 + len(bw) - 1:04X}) -- "
              f"working bank={rw.get('bank')}/{rw.get('aux_bank')}  "
              f"direct bank={rd.get('bank')}/{rd.get('aux_bank')} --")
        ndiff = 0
        for i in range(min(len(bw), len(bd))):
            if bw[i] != bd[i]:
                ndiff += 1
                print(f'   ${addr0+i:04X}: working=${bw[i]:02X} '
                      f'direct=${bd[i]:02X}')
        if ndiff == 0:
            print('   (identical)')
        print(f'   {ndiff} byte(s) differ / {len(bw)} total')
        print()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
