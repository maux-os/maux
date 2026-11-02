#!/usr/bin/env python3
"""Independent native replacement oracle, including explicit VM services.

The CPU never executes VM code. Service values are independently supplied;
guest gates separately verify the real evaluator/labels/flush integration.
"""
from pathlib import Path
import check_nas_loop_native as old
from build_nas_replace import FIELDS, source_variant

ROOT = Path(__file__).resolve().parents[1]


def main(capacity_cases=(511,512), source=None):
    if source is None:
        original = (ROOT / 'src/asm/nas.pla').read_text()
        shared = (ROOT / 'src/asm/nasloop.pla').read_text().split('asm fastloop(',1)[0]
        source = source_variant(original,shared+(ROOT / 'src/asm/nasreplace.pla').read_text())
    old.FIELDS = FIELDS
    funcs = tuple(f for f in old.FUNCS if f not in ('modeprobe','fastloop')) + ('fastprobe','fastloop')
    total, first = 0, None
    def invoke(*args, **kwargs):
        return old.invoke(*args, extra_slots=7, context_end=86, **kwargs)
    forms = ('', '', '#$12', '$12', '$12,X', '$12,Y',
             '$1234', '$1234,X', '$1234,Y', '($1234)',
             '($12,X)', '($12),Y', '($12)', '($1234,X)', '$2002')
    for origin in (0x4000,0x41F9):
        tmp, code, entry = old.assemble(source,funcs,origin)
        try:
            assert first is None or first == code
            first = code
            for i,(a,b,c,mode,op,cmos) in enumerate(old.optab_rows()):
                line=b' '+bytes((a,b,c))+b' '+forms[mode].encode()+b'\r dfb 0\r'
                size=old.MODESIZE[mode]
                value=0 if mode==14 else (0x1234 if mode in (6,7,8,9,13) else 0x12)
                expected=bytes([op])+value.to_bytes(2,'little')[:size-1]
                for phase in (1,2):
                    for xc in (0,1):
                        mem,ret,_=invoke(code,entry,origin,line,phase,op,x=7+i%24,xc=xc)
                        if phase==1 and cmos and not xc:
                            assert ret==103 and old.word(mem,0x6276)==0x2000,(line,ret)
                        else:
                            assert ret==13 and old.word(mem,0x6276)==0x2000+size,(line,phase,xc,ret)
                            assert mem[old.STREAM]==op,(line,op,mem[old.STREAM])
                            if phase==2:
                                assert bytes(mem[old.OUTPUT:old.OUTPUT+size])==expected,(line,expected)
                        total+=1
            for mnemonic,op in (('asl',0x0A),('lsr',0x4A),('rol',0x2A),('ror',0x6A),('inc',0x1A),('dec',0x3A)):
                for operand in ('A','a'):
                    for phase in (1,2):
                        mem,ret,_=invoke(code,entry,origin,f' {mnemonic} {operand}\r dfb 0\r'.encode(),phase,op)
                        assert ret==13 and mem[old.STREAM]==op,(mnemonic,operand,phase,mem[old.STREAM])
                        if phase==2: assert mem[old.OUTPUT]==op
                        total+=1
            for phase in (1,2):
                for rel in (0,1):
                    for value in (0x12,0x1234):
                        seen=[]
                        def evaluate(mem,ret,events):
                            if ret not in (100,101): return False
                            p=old.word(mem,old.CTX+54); n=old.word(mem,old.CTX+56)
                            assert bytes(mem[p:p+n])==b'<MISSING+1'
                            seen.append(ret)
                            for at,v in ((52,value),(76,value),(78,rel),(80,0),(82,60),(84,2 if ret==100 else 3)):
                                old.putword(mem,old.CTX+at,v)
                            return True
                        op=0x85 if value<256 and not rel else 0x8D
                        mem,ret,_=invoke(code,entry,origin,b' sta <MISSING+1\r dfb 0\r',phase,op,rel=rel,service=evaluate)
                        assert ret==13 and seen==[100 if phase==1 else 101],(phase,rel,value,ret,seen)
                        assert mem[old.STREAM]==op
                        total+=1
            for phase in (1,2):
                for dum in (0,1):
                    def label(mem,ret,events):
                        if ret!=0: return False
                        old.putword(mem,old.CTX+84,1)
                        return True
                    mem,ret,_=invoke(code,entry,origin,b'LABEL lda #1\r dfb 0\r',phase,0xA9,dum=dum,service=label)
                    assert ret==13 and old.word(mem,0x6276)==0x2002
                    assert old.word(mem,0x6262 if phase==1 else 0x6264)==1
                    if phase==2:
                        assert old.word(mem,0x6272)==(0 if dum else 2)
                    total+=1
            for fill in (510,511,512):
                def flush(mem,ret,events):
                    if ret!=102: return False
                    assert old.word(mem,0x6276)==0x2000 and old.word(mem,0x6264)==0
                    old.putword(mem,0x6272,0)
                    old.putword(mem,old.CTX+84,3)
                    return True
                mem,ret,_=invoke(code,entry,origin,b' lda #1\r dfb 0\r',2,0xA9,fill=fill,service=flush)
                assert ret==13 and old.word(mem,0x6276)==0x2002 and old.word(mem,0x6264)==1
                total+=1
            # Frozen replay is consumed exactly once, even across repeated
            # native instructions. Includes all legal caller stack slots.
            for x in range(7,31):
                for phase in (1,2):
                    data=b' lda #$12\r sta $12,X\r nop\r'*16+b' dfb 0\r'
                    replay=bytes.fromhex('a995ea')*16
                    mem,ret,_=invoke(code,entry,origin,data,phase,0xA9,x=x,replay=replay)
                    assert ret==13 and old.word(mem,0x6276)==0x2050
                    assert old.word(mem,0x6262 if phase==1 else 0x6264)==48
                    assert bytes(mem[old.STREAM:old.STREAM+48])==replay
                    if phase==2:
                        assert bytes(mem[old.OUTPUT:old.OUTPUT+80])==bytes.fromhex('a9129512ea')*16
                    total+=1
            for count in capacity_cases:
                mem,ret,_=invoke(code,entry,origin,b' nop\r dfb 0\r',1,0xEA,count=count)
                assert ret==(13 if count==511 else 103)
                assert old.word(mem,0x6262)==512
                assert old.word(mem,0x6276)==0x2000+(count==511)
                total+=1
            for operand in ('$2082','$1f81'):
                mem,ret,_=invoke(code,entry,origin,f' bne {operand}\r dfb 0\r'.encode(),2,0xD0)
                assert ret==105 and old.word(mem,0x6264)==0 and old.word(mem,0x6276)==0x2000
                total+=1
            mem,ret,_=invoke(code,entry,origin,b' sta SYM\r dfb 0\r',2,0x8D,rel=1,symbol_flags=1,fixlimit=0)
            assert ret==106 and old.word(mem,0x6264)==0 and old.word(mem,0x6276)==0x2000
            assert old.word(mem,0x6282)==0 and old.word(mem,0x6272)==0
            total+=1
            for operand,value in (('$2081',127),('$1f82',128)):
                mem,ret,_=invoke(code,entry,origin,f' bne {operand}\r dfb 0\r'.encode(),2,0xD0)
                assert ret==13 and bytes(mem[old.OUTPUT:old.OUTPUT+2])==bytes([0xD0,value])
                total+=1
            for phase in (1,2):
                mem,ret,_=invoke(code,entry,origin,b' lda A\r dfb 0\r',phase,0xAD)
                assert ret==(100 if phase==1 else 101) and old.word(mem,0x6276)==0x2000
                total+=1
            for flags in (0,1,3,4,5,17,19):
                for rel in (0,1):
                    for phase in (1,2):
                        for operand in ('SYM','<SYM','>SYM'):
                            op=0x8D
                            mem,ret,_=invoke(code,entry,origin,f' sta {operand}\r dfb 0\r'.encode(),phase,op,
                                             rel=rel,symbol_flags=flags,symbol_value=0x1234)
                            refused=not(flags&5) or bool(flags&16)
                            assert ret==((100 if phase==1 else 101) if refused else 13),(flags,rel,phase,operand,ret)
                            if refused:
                                p=old.word(mem,old.CTX+54);n=old.word(mem,old.CTX+56)
                                assert bytes(mem[p:p+n])==operand.encode()
                                assert old.word(mem,0x6276)==0x2000
                            else:
                                value=0 if flags&4 else 0x1234
                                value=value&255 if operand.startswith('<') else (value>>8 if operand.startswith('>') else value)
                                kind=2 if flags&4 else (0 if flags&2 else 1)
                                expected_op=0x85 if value<256 and (not rel or not kind) else 0x8D
                                if phase==1: assert mem[old.STREAM]==expected_op
                                if phase==2:
                                    # Replay is deliberately ABS even for a
                                    # final low value: never resize in pass2.
                                    raw=(0x8000+(0 if flags&4 else 0x1234)) if rel and kind else value
                                    assert bytes(mem[old.OUTPUT:old.OUTPUT+3])==b'\x8d'+raw.to_bytes(2,'little'), (flags,rel,operand,value,bytes(mem[old.OUTPUT:old.OUTPUT+3]).hex(),hex(raw))
                            total+=1
            try:
                invoke(code,entry,origin,b' nop\r',1,0xEA,poison=True)
            except AssertionError:
                pass
            else:
                raise AssertionError('sabotage accepted')
        finally:
            tmp.cleanup()
    print(f'PASS: {total} replacement cases, two-origin identical {len(first)}B closure; native-only, services, ABI/write guards, sabotage')


if __name__=='__main__':
    main()
