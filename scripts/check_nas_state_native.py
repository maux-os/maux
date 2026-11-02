#!/usr/bin/env python3
"""Run the independent replacement oracle with the private native ABI."""
import check_nas_replace_native as check
from build_nas_state import source_variant, CALL_OFFSETS
import check_nas_line_native as line


def check_init(source):
    frozen=None
    seed=bytes((i*73+19)&255 for i in range(86))
    for origin in (0x4000,0x41F9):
        tmp,code,entry=line.assemble(source,('initloop',),origin)
        try:
            assert frozen is None or frozen==code
            frozen=code
            for x in range(32):
                def setup(mem):mem[0x7000:0x7056]=seed
                mem=line.call(code,origin,entry['initloop'],[0x7000],0,setup,
                              set(range(0x10,0x66))|set(range(0x70,0x8E)),x,False)
                assert bytes(mem[0x10:0x66])==seed
                for i,off in enumerate(CALL_OFFSETS):
                    assert bytes(mem[0x70+i*3:0x73+i*3])==b'\x4C'+seed[off:off+2]
        finally:tmp.cleanup()
    print('PASS: 64 native-state initialization cases, poisoned memory, all X, two origins')


def main():
    check.source_variant = source_variant
    old = check.old
    old.CTX = 0x10
    original = old.invoke

    def prepare(mem, entry):
        for i, off in enumerate(CALL_OFFSETS):
            at = 0x70+i*3
            mem[at] = 0x4C
            old.putword(mem, at+1, old.word(mem, old.CTX+off))

    def invoke(*args, **kwargs):
        return original(*args, prepare=prepare,
                        executable=tuple(0x70+i*3 for i in range(10)), **kwargs)

    old.invoke = invoke
    check.main()
    shared=(check.ROOT/'src/asm/nasloop.pla').read_text().split('asm fastloop(',1)[0]
    check_init(source_variant((check.ROOT/'src/asm/nas.pla').read_text(),
                              shared+(check.ROOT/'src/asm/nasreplace.pla').read_text()))


if __name__ == '__main__':
    main()
