#!/usr/bin/env python3
"""Build NAS with a private fixed zero-page native interface; opt-in only."""
import argparse
import re
import sys

import build_nas_replace as replacement

ROOT = replacement.ROOT
FIELDS = replacement.FIELDS
CALL_OFFSETS = tuple(range(32, 50, 2)) + (74,)
FUSED_READER = False


def fuse_reader(source):
    match = re.search(r'^asm lineprep\([^\n]*\n(.*?)^end$', source, re.M | re.S)
    old = match[1]
    parser = old.split('LPPARSE ',1)[1].split('\nLPCLASS\n',1)[0]
    parser = parser[parser.index('        LDA     #$00\n        LDY     #$02'):]
    parser = re.sub(r'\bCPY\s+TMPL', '+NSBOUND', parser)
    parser = re.sub(r'(\+NSBOUND\n\s+BCS\s+\w+\n)\s+LDA\s+\(SRC\),Y\n', r'\1', parser)
    parser = parser.replace('(DST),Y', '$8E,Y')
    parser = parser.replace('        LDA     TMPL\n        BEQ     TKDONE0',
        '        LDY     #0\n        +NSBOUND\n        LDA     TMPL\n        BEQ     TKDONE0')
    parser = parser.replace('TKDONE0 LDY', 'TKDONE0 STY     $6C\n        LDY')
    a = parser.index('LPEARLY ')
    b = parser.index('TKMN0 ', a)
    parser = parser[:a] + 'LPEARLY STA     $6D\n        +NSGO NSFIN\n' + parser[b:]
    parser = parser.replace('TKDONE1 CLC\n        BCC     ', 'TKDONE1 STY     $6C\n        +NSGO ')
    # The parser contains a branch to LPCLASS before its final fallthrough.
    parser = parser.replace('+NSGO LPCLASS', '+NSGO NSFIN')
    parser = parser.replace('TKOPE   TYA', 'TKOPE   STY     $6C\n        TYA')
    template = (ROOT/'src/asm/nasread.pla').read_text()
    template = template.replace('// TOKENIZER inserted here by the builder.', parser)
    template = template.replace('// CLASSIFIER inserted here by the builder.',
                                old.split('\nLPCLASS\n',1)[1])
    return source[:match.start()] + template.rstrip() + source[match.end():]


def source_variant(source, native):
    if FUSED_READER:
        source = fuse_reader(source)
    macros = (ROOT / 'src/asm/nasstate.pla').read_text()
    # Macro bodies may contain ACME conditional braces; use the next
    # top-level macro declaration as their boundary.
    for part in re.split(r'(?=^!macro )', macros, flags=re.M)[1:]:
        name = re.match(r'!macro (\w+)', part)[1]
        pattern = r'^!macro ' + name + r'\b[^\n]*\{\n.*?^}\n'
        native, n = re.subn(pattern, lambda _: part.rstrip()+'\n', native,
                            count=1, flags=re.M | re.S)
        assert n == 1, name
    # Only these three functions use DST as the descriptor pointer. Other
    # native helpers retain their own ABI and SRC/DST scratch ownership.
    native = native.replace('(DST),Y', '$10,Y')
    result = replacement.source_variant(source, native)
    result = result.replace('word loopctx[] = ', 'word loopseed[] = ', 1)
    result = result.replace('loopctx[', '$10=>[').replace('@loopctx', '$10')
    init = '''asm initloop(seed)#0
        LDA ESTKL,X
        STA SRCL
        LDA ESTKH,X
        STA SRCH
        LDY #85
NSCOPY  LDA (SRC),Y
        STA $10,Y
        DEY
        BPL NSCOPY
'''
    for i, off in enumerate(CALL_OFFSETS):
        at = 0x70 + i*3
        init += f'''        LDA #$4C
        STA ${at:02X}
        LDA ${0x10+off:02X}
        STA ${at+1:02X}
        LDA ${0x11+off:02X}
        STA ${at+2:02X}
'''
    init += '        INX\n        RTS\nend\n'
    result = replacement.replace_once(result, 'asm fastvalue(ctx)#1',
                                      init+'asm fastvalue(ctx)#1')
    result = replacement.replace_once(result, '    word arg, lc, sc, lo, cl, hi\n',
        '    word arg, lc, sc, lo, cl, hi\n    initloop(@loopseed)\n')
    return result


def main():
    global FUSED_READER
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output-dir', default=str(ROOT/'build/nas-state'))
    ap.add_argument('--fused-reader', action='store_true')
    args = ap.parse_args()
    FUSED_READER = args.fused_reader
    base = replacement.base
    base.source_variant, base.FIELDS = source_variant, FIELDS
    base.NATIVE_SOURCE = ROOT/'src/asm/nasreplace.pla'
    sys.argv = [sys.argv[0], '--output-dir', args.output_dir]
    base.main()


if __name__ == '__main__':
    main()
