#!/usr/bin/env python3
"""Independent tokenizer/reader oracle for the fused transactional reader."""
from pathlib import Path
import check_nas_line_native as check


def main():
    original = check.call
    scratch = set(range(0x0A,0x10)) | set(range(0x66,0x70)) | set(range(0x8E,0x9C))

    def call(code, origin, entry, args, result, setup, allowed=(), x=0, returns=True):
        def extra(mem):
            check.putword(mem,0x30,entry)
            mem[0xE6] = 0x4C
        return original(code,origin,entry,args,result,setup,set(allowed)|scratch,
                        x,returns,extra_setup=extra)

    check.call = call
    check.check_source(Path('build/nas-fused/nas.pla'))


if __name__ == '__main__':
    main()
