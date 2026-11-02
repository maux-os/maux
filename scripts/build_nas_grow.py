#!/usr/bin/env python3
"""Opt-in two-pass NAS: incremental symbols/locals/ERR and paged replay."""
import argparse
import re
import sys

import build_nas_state as state

ROOT = state.ROOT
once = state.replacement.replace_once


def function(source, name, body=None):
    pattern = r'^' + ('asm' if name == 'scan0' else 'def') + r' ' + name + r'\b.*?^end\n'
    source,n = re.subn(pattern, lambda _: body or '', source, count=1, flags=re.M|re.S)
    assert n == 1, name
    return source


def source_variant(source, native):
    # The runtime bump allocator does not detect 16-bit addition wrap.
    # Large deferred fixup requests must be rejected BEFORE calling it.
    source=once(source,'    p = heapalloc(n)\n', '''    p = 0
    if isule(n, heapavail())
        p = heapalloc(n)
    fin
''')
    source = function(function(source,'pass0'),'scan0')
    source = once(source, 'word symrec ', 'word symtail, modehead, modepage, errtail, retrytail\nword symrec ')
    a=source.index('    if numsyms >= maxsyms\n')
    b=source.index('    *rp = namep\n',a)
    source=source[:a]+'''    zone = reszone(p, l)
    rp = newsymbol(l)
    if not rp
        return 0
    fin
    namep = rp + SYMRSZ + 2
    ^namep = l
    memcpy(namep + 1, p, l)
'''+source[b:]
    # Native findsymh still consumes the unchanged first nine record bytes.
    source=once(source,'            rp = rp + SYMRSZ\n','            rp = *(rp + SYMRSZ)\n')
    source=once(source,'''                    idx = addsym(g_labelptr, g_labellen, 0, 1)
                fin
                ^(idx + 8)''','''                    idx = addsym(g_labelptr, g_labellen, 0, 1)
                fin
                if not idx
                    break
                fin
                ^(idx + 8)''')
    source=once(source,'def findloc(p, l)#1\n    word i, namep\n',
        'def findloc(p, l)#1\n    word i, namep\n    if not lochead\n        return 0\n    fin\n')
    source=once(source,'''    if numlocs >= maxlocs
        errflag = 1
        return
    fin
''','''    if not lochead
        lochead = xalloc(HASHSIZE * 2)
        if not lochead
            return
        fin
        h = 0
        while h < HASHSIZE
            lochead=>[h] = 0
            h++
        loop
    fin
    locnext = xalloc(6)
    if not locnext
        return
    fin
''')
    source=once(source,'    locnext = locnext + 6\n','')
    a=source.index('    if errfill + 5 + l > errbytes\n')
    b=source.index('    *ep = star\n',a)
    source=source[:a]+'''    ep = xalloc(7 + l)
    if not ep
        return
    fin
    *ep = 0
    ep = ep + 2
    if errtail
        *(errtail - 2) = ep
    else
        errlist = ep
    fin
    errtail = ep
'''+source[b:]
    source=once(source,'        rp = rp + 5 + ^(rp + 4)\n','        rp = *(rp - 2)\n')
    source=once(source,'    rp = retry + numretry * RETRYREC\n', '''    rp = xalloc(9 + l)
    if not rp
        return
    fin
    *rp = 0
    rp = rp + 2
    if retrytail
        *(retrytail - 2) = rp
    else
        retry = rp
    fin
    retrytail = rp
''')
    source=once(source,'''        i2 = 0
        while i2 < numretry
            rp = retry + i2 * RETRYREC
''','''        i2 = 0
        rp = retry
        while i2 < numretry
''')
    source=once(source,'''            i2++
        loop
        iter++
''','''            rp = *(rp - 2)
            i2++
        loop
        iter++
''')
    source=once(source,'''    i2 = 0
    while i2 < numretry
        idx = *(retry + i2 * RETRYREC)
''','''    i2 = 0
    rp = retry
    while i2 < numretry
        idx = *rp
''')
    source=once(source,'''            ^(idx + 8) = ^(idx + 8) & ~F_PROV
        fin
        i2++
''','''            ^(idx + 8) = ^(idx + 8) & ~F_PROV
        fin
        rp = *(rp - 2)
        i2++
''')
    a=source.index('    lc, sc, lo, cl = pass0()\n')
    b=source.index('    pass1()\n',a)
    source=source[:a]+'''    symrec = 0
    symtail = 0
    lochead = 0
    locmask = HASHSIZE - 1
    numlocs = 0
    modehead = 0
    modepage = 0
    errlist = 0
    errtail = 0
    newmodepage()
    retry = 0
    retrytail = 0
    hashhead = xalloc(HASHSIZE * 2)
    if errflag
        return 1
    fin
    hi = 0
    while hi < HASHSIZE
        hashhead=>[hi] = 0
        hi++
    loop

'''+source[b:]
    source=once(source,'    pass2()\n','''    *(modepage + 2) = modecnt
    modepage = modehead
    modestrm = modepage + 4
    modecnt = *(modepage + 2)
    pass2()
''')
    source=once(source,'if not errflag and modepos <> modecnt',
        'if not errflag and (modepos <> modecnt or *modepage)')
    # New definitions must follow xalloc and precede their first callers.
    at=source.index('\ndef toup(')
    source=source[:at]+'\n'+(ROOT/'src/asm/nasgrow.pla').read_text()+source[at:]
    native=once(native,'NRRES3  +NLGOTO NREMIT','''NRRES3  CMP #4
        BNE NRRESUME
        +NLGOTO NRCHOSEN
NRRESUME +NLGOTO NREMIT''')
    native=once(native,'NRCHOSEN +NLARG 58','''NRCHOSEN +NLPTR 16
        LDY #3
        LDA (SRC),Y
        BEQ NRHAVE
        +NRRET 107
NRHAVE  +NLARG 58''')
    native=once(native,'NRSTREAM +NRRET 104','NRSTREAM +NRRET 108')
    source=state.source_variant(source,native)
    source=once(source,'    elsif d == 102\n', '''    elsif d == 107
        newmodepage()
        $10=>[42] = 4
    elsif d == 108
        nextmodepage()
        $10=>[42] = 1
    elsif d == 102
''')
    return source


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output-dir', default=str(ROOT/'build/nas-grow'))
    ap.add_argument('--fused-reader', action='store_true')
    args=ap.parse_args()
    state.FUSED_READER=args.fused_reader
    base=state.replacement.base
    base.source_variant,base.FIELDS=source_variant,state.FIELDS
    base.NATIVE_SOURCE=ROOT/'src/asm/nasreplace.pla'
    sys.argv=[sys.argv[0],'--output-dir',args.output_dir]
    base.main()


if __name__=='__main__':main()
