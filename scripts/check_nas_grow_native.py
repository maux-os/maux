#!/usr/bin/env python3
"""Independent instruction and multi-page continuation oracles, no VM."""
import check_nas_replace_native as check
from build_nas_state import CALL_OFFSETS, ROOT
from check_nas_state_native import check_init


def prepare(mem, entry):
    for i,off in enumerate(CALL_OFFSETS):
        mem[0x70+i*3] = 0x4C
        check.old.putword(mem,0x71+i*3,check.old.word(mem,0x10+off))


def main():
    old=check.old
    old.CTX=0x10
    original=old.invoke
    def invoke(*args, **kwargs):
        kwargs.setdefault('extra_slots',7)
        kwargs.setdefault('context_end',86)
        return original(*args,prepare=prepare,
                        executable=tuple(0x70+i*3 for i in range(10)),**kwargs)
    old.invoke=invoke
    src=(ROOT/'src/asm/nas.pla').read_text()
    check.main(capacity_cases=(), source=src)
    old.SOURCE=0x2000  # 1,025 lines must not overlap symbols/replay pages.
    check_init(src)
    funcs=tuple(f for f in old.FUNCS if f not in ('modeprobe','fastloop'))+('fastprobe','fastloop')
    pages=(0xA200,0xA300,0xB800,0xB900,0xBA00)
    cases=0
    for origin in (0x4000,0x41F9):
        temp,code,entry=old.assemble(src,funcs,origin)
        try:
            for n in (255,256,257,511,512,513,1025):
                for phase in (1,2):
                    recorded=[];emitted=[];page=[0]
                    def service(mem,ret,events):
                        if ret==107:
                            assert phase==1 and old.word(mem,0x6262)==256
                            recorded.extend(mem[pages[page[0]]:pages[page[0]]+256])
                            page[0]+=1
                            old.putword(mem,0x6260,pages[page[0]])
                            old.putword(mem,0x6262,0)
                            old.putword(mem,0x6266,256)
                            old.putword(mem,old.CTX+84,4)
                            return True
                        if ret==108:
                            assert phase==2 and old.word(mem,0x6264)==256
                            page[0]+=1
                            size=min(256,n-page[0]*256)
                            assert size>0
                            mem[pages[page[0]]:pages[page[0]]+size]=[0xEA]*size
                            old.putword(mem,0x6260,pages[page[0]])
                            old.putword(mem,0x6262,size)
                            old.putword(mem,0x6264,0)
                            old.putword(mem,old.CTX+84,1)
                            return True
                        if ret==102:
                            fill=old.word(mem,0x6272)
                            assert fill==512
                            emitted.extend(mem[old.OUTPUT:old.OUTPUT+fill])
                            old.putword(mem,0x6272,0)
                            old.putword(mem,old.CTX+84,3)
                            return True
                        return False
                    mem,ret,_=invoke(code,entry,origin,b' nop\r'*n+b' dfb 0\r',phase,0xEA,
                        replay=bytes([0xEA])*min(n,256),capacity=256,service=service,
                        extra_writes=range(0xB800,0xBB00),max_steps=3000000)
                    assert ret==13 and old.word(mem,0x6276)==0x2000+n,(n,phase,ret)
                    assert page[0]==(n-1)//256
                    if phase==1:
                        count=old.word(mem,0x6262)
                        recorded.extend(mem[pages[page[0]]:pages[page[0]]+count])
                        assert bytes(recorded)==bytes([0xEA])*n
                    else:
                        emitted.extend(mem[old.OUTPUT:old.OUTPUT+old.word(mem,0x6272)])
                        assert bytes(emitted)==bytes([0xEA])*n
                    cases+=1
            # A refused page allocation has not advanced PC or published
            # another opcode. The real VM's OOM handling is a guest test.
            mem,ret,_=invoke(code,entry,origin,b' nop\r',1,0xEA,count=256,capacity=256)
            assert ret==107 and old.word(mem,0x6276)==0x2000 and old.word(mem,0x6262)==256
            cases+=1
        finally:temp.cleanup()
    print(f'PASS: {cases} additional replay-page/flush/refusal cases at two origins')


if __name__=='__main__':main()
