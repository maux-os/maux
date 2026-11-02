#!/usr/bin/env python3
"""Build the opt-in single-owner instruction-control experiment.

Unlike nas-loop, remove decidemode/operandvalue and both PLASMA instruction
bodies. PLASMA services native continuations, not a duplicate instruction.
"""
import argparse
from pathlib import Path
import sys

import build_nas_loop as base

ROOT = base.ROOT
FIELDS = tuple('@fastprobe' if f == '@modeprobe' else f for f in base.FIELDS) + ('0',)


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('source anchor changed: ' + old[:70])
    return source.replace(old, new)


def source_variant(source, native):
    # Compiler predefs resolve to the native entry alias, so the cooker
    # relocates these once and restores them on warm launch. No run-time
    # descriptor construction or duplicate initializer bytecode is needed.
    prototypes = ('lineprep(a,b,c,d)#1', 'mnlook(a,b,c,d,e)#0',
                  'numscan(a,b,c)#1', 'namescan(a,b,c)#1',
                  'findsymh(a,b,c,d)#1', 'fastprobe(a)#1',
                  'noteinst(a,b,c,d)#1', 'commitinst(a,b,c,d,e)#1',
                  'fastloop(a,b)#1', 'fastvalue(a)#1')
    descriptor = ''.join('predef ' + p + '\n' for p in prototypes)
    descriptor += 'word loopctx[] = ' + ','.join(FIELDS[:8]) + '\n'
    descriptor += ''.join('word = ' + ','.join(FIELDS[i:i+8]) + '\n'
                          for i in range(8,len(FIELDS),8))
    source = replace_once(source, 'export asm ckdataend()#0',
                          descriptor + 'export asm ckdataend()#0')
    source = replace_once(source, 'def xalloc(n)#1', native + '\ndef xalloc(n)#1')
    start = source.index('def decidemode(')
    end = source.index('def isquoteitem(', start)
    source = source[:start] + source[end:]
    start = source.index('asm modeprobe(')
    end = source.index('\nend', start) + len('\nend')
    source = source[:start] + source[end:]
    service_body = None
    for phase in (1, 2):
        start = source.index(f'def pass{phase}#0')
        end = source.index('\nend', start)
        body = source[start:end]
        body = body.replace('    while not errflag\n',
                            '    loopctx[42] = 0\n    while not errflag\n', 1)
        body = replace_once(body,
            'd = lineprep(@rd_buf0 + rd_inputt, @g_line, @g_labelptr, @dirhash)',
            f'd = fastloop(@loopctx, {phase})')
        # Services are handled before label/zone/curstar bookkeeping: a
        # continuation must not define/check the same label twice.
        service = '''        if d >= 100
            if d == 100 or d == 101
                loopctx[26], ok = evalexpr(loopctx[27], loopctx[28])
                loopctx[39] = 0
                if relflag
                    loopctx[39] = g_ek
                fin
                loopctx[40] = g_ern
                loopctx[38] = g_eraw
                loopctx[41] = g_esel
                if d == 100
                    if not ok
                        loopctx[39] = 1
                    fin
                    loopctx[42] = 2
                else
                    loopctx[42] = 3
                fin
            elsif d == 102
                outflush()
                loopctx[42] = 3
            else
                if d == 104
                    eputs("nas: phase error: mode stream line ")
                elsif d == 105
                    eputs("nas: branch out of range line ")
                elsif d == 106
                    eputs("nas: fixup table full line ")
                fin
                if d <> 103
                    eputi(g_lineno); eputln
                fin
                errflag = 1
            fin
            continue
        fin
'''
        service_body = service.split('        if d >= 100\n', 1)[1].rsplit('            continue\n', 1)[0]
        body = replace_once(body, '        if d < 0\n',
            '        if d >= 100\n            loopservice(d)\n            continue\n        fin\n        if d < 0\n')
        a = body.index('        elsif d == D_CODE\n')
        b = body.index('        elsif d == D_DFB\n', a)
        label = 'deflabel(curpc)' if phase == 1 else 'phasecheck()'
        body = body[:a] + f'''        elsif d == D_CODE
            if g_labellen
                {label}
            fin
            loopctx[42] = 1
''' + body[b:]
        # Reader-boundary lines and labeled instructions resume at the same
        # native instruction entry on the next loop, without a second parse.
        if phase == 2:
            body = body.replace('    word d\n', '    word d, ok\n', 1)
        source = source[:start] + body + source[end:]
    service_body = '\n'.join(line[8:] for line in service_body.splitlines())
    source = replace_once(source, 'def pass1#0',
        'def loopservice(d)#0\n    word ok\n' + service_body + '\nend\ndef pass1#0')
    return source


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output-dir', type=Path, default=ROOT / 'build/nas-replace')
    args = ap.parse_args()
    # Keep the proven compiler/cooker pipeline; only its source transform
    # changes. The first prototype's scalar helper/macros remain shared.
    base.source_variant = source_variant
    base.FIELDS = FIELDS
    base.NATIVE_SOURCE = ROOT / 'src/asm/nasreplace.pla'
    sys.argv = [sys.argv[0], '--output-dir', str(args.output_dir)]
    base.main()


if __name__ == '__main__':
    main()
