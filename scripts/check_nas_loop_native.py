#!/usr/bin/env python3
"""Independent CPU oracle for the opt-in whole native instruction loop.

Actual source assembly, two origins, canary memory, no VM execution, exact
instruction bytes and stream/PC effects. Not part of production check-all.
"""
from pathlib import Path
import re
from py65.devices.mpu6502 import MPU

from build_nas_loop import FIELDS, source_variant
from check_nas_line_native import (assemble, table, TracedMemory, putword,
                                   word, stackargs, stackword, MODESIZE)
from check_nas_mode_native import optab_rows
from check_nas_note_native import tables

ROOT = Path(__file__).resolve().parents[1]
FUNCS = ('lineprep', 'findsymh', 'numscan', 'namescan', 'mnlook',
         'commitinst', 'noteinst', 'modeprobe', 'fastvalue', 'fastloop')
GLOBALS = dict(g_line=0x6200, g_labelptr=0x6210, dirhash=0x8600,
               rd_buf0=0x6230, mnhead=0x8900, optab=0x8000, g_blo=0x6250,
               opmode=0x8D00, modestrm=0x6260, outbuf=0x6270, fxrec=0x6280,
               xcflag=0x6290, dumflag=0x6291, hashhead=0x6294,
               curzone=0x6296, curstar=0x6298, rd_inputt=0x629A,
               modeprefix=0x8E20, modetrim=0x8E40)
CTX, SOURCE, OUTPUT, STREAM = 0x6000, 0xA8FD, 0xA400, 0xA200


def mnemonic_tables(source):
    region = source.split('byte mnhead[] = ', 1)[1].split('// ---- CONSTANT', 1)[0]
    result, width = [], 1
    for line in region.splitlines():
        line = line.split('//', 1)[0].strip()
        if not line:
            continue
        if '=' in line:
            width = 2 if line.startswith('word') else 1
            line = line.split('=', 1)[1]
        for value in line.split(','):
            n = int(value.strip())
            result.extend(n.to_bytes(width, 'little'))
    assert len(result) == 968
    return result


def invoke(code, entry, origin, source, phase, opcode, *, x=30, xc=1,
           rel=0, symbol_flags=3, symbol_value=0x12, symbol_zone=0xFFFF,
           zone=0, fill=0, count=0, capacity=512, dum=0, poison=False,
           replay=None, extra_slots=5, context_end=84, service=None,
           fixlimit=32, prepare=None, executable=(), extra_writes=(), max_steps=500000):
    mem = TracedMemory()
    mem[origin:origin+len(code)] = code
    # Every descriptor pointer is explicit; no mutable state lives in code.
    pointers = GLOBALS | entry
    for i, field in enumerate(FIELDS):
        putword(mem, CTX + i*2, pointers[field[1:]] if field.startswith('@') else int(field))
    baseline = (ROOT / 'src/asm/nas.pla').read_text()
    for addr, values in ((0x8000, [v for row in optab_rows() for v in row]),
                         (0x8600, table(baseline)[0]),
                         (0x8900, mnemonic_tables(baseline)),
                         (0x8D00, tables(baseline)),
                         (0x8E20, [0,0,1,0,0,0,0,0,0,1,1,1,1,1,0]),
                         (0x8E40, [0,0,1,0,2,2,0,2,2,2,4,4,2,4,0])):
        mem[addr:addr+len(values)] = values
    mem[0x6200:0x62A0] = [0] * 0xA0
    mem[SOURCE:SOURCE+len(source)] = source
    for at, val in ((0x6230, SOURCE), (0x6232, 0), (0x6234, len(source)),
                    (0x6260, STREAM), (0x6262, count if phase == 1 else len(replay or [opcode])),
                    (0x6264, 0), (0x6266, capacity),
                    (0x6270, OUTPUT), (0x6272, fill), (0x6274, fill),
                    (0x6276, 0x2000), (0x627A, 0x2000),
                    (0x6280, 0xB800), (0x6284, fixlimit),
                    (0x6294, 0xA000), (0x6296, zone)):
        putword(mem, at, val)
    mem[STREAM] = opcode
    if replay:
        mem[STREAM:STREAM+len(replay)] = replay
    mem[0x6290], mem[0x6291], mem[0x628C] = xc, dum, rel
    # One raw-case symbol in its actual hash bucket, with independent layout.
    mem[0xA000:0xA100] = [0]*256
    name = b'SYM'
    h = len(name)
    for c in name:
        h = (h*5+c) & 255
    putword(mem, 0xA000 + 2*(h & 127), 0xB100)
    mem[0xB200:0xB204] = bytes([3])+name
    for at, val in ((0xB100,0xB200), (0xB102,symbol_value),
                    (0xB104,symbol_zone), (0xB106,0)):
        putword(mem, at,val)
    mem[0xB108] = symbol_flags
    for at in range(0xA0,0x100):
        mem[at] = (at*73+x*31)&255
    stackargs(mem, [CTX, phase], x)
    mem[0xE6] = 0x4C  # actual PLASMA JMPTMP trampoline
    mem[0x1F1:0x1F3] = [0xFF,0x2F]
    if prepare:
        prepare(mem, entry)
    if poison:
        mem[entry['fastloop']] = 0x60
    cpu = MPU(memory=mem)
    cpu.pc,cpu.x,cpu.sp,cpu.p = entry['fastloop'],x,0xF0,0x30
    mem.recording = True
    services = []
    for _ in range(max_steps):
        assert origin <= cpu.pc < origin+len(code) or cpu.pc == 0xE6 or cpu.pc in executable, hex(cpu.pc)
        cpu.step()
        if cpu.pc == 0x3000:
            assert cpu.x == x+1 and cpu.sp == 0xF2, ('ABI',cpu.x,cpu.sp)
            if service:
                ret = stackword(mem,x+1)
                mem.recording = False
                again = service(mem, ret, services)
                mem.recording = True
                if again:
                    services.append(ret)
                    assert len(services) < 100, ('service loop', services)
                    mem.recording = False
                    stackargs(mem, [CTX,phase],x)
                    mem[0x1F1:0x1F3] = [0xFF,0x2F]
                    mem.recording = True
                    cpu.pc,cpu.x,cpu.sp = entry['fastloop'],x,0xF0
                    continue
            break
    else:
        raise AssertionError(('timeout',hex(cpu.pc)))
    assert cpu.x == x+1 and cpu.sp == 0xF2, ('ABI',cpu.x,cpu.sp)
    allowed = set(range(6,10)) | {0x9E,0xE7,0xE8}
    allowed |= set(range(0xA0+x-extra_slots,0xA0+x+2)) | set(range(0xC0+x-extra_slots,0xC0+x+2))
    allowed |= set(range(0x1E0,0x1F1)) | set(range(CTX+50,CTX+68))
    allowed |= set(range(CTX+76,CTX+84))
    allowed |= set(range(CTX+84,CTX+context_end))
    allowed |= set(range(0x6200,0x6206)) | set(range(0x6210,0x621E))
    allowed |= {0x6232,0x6233} | set(range(0x6250,0x625C))
    allowed |= set(range(0x6262,0x6266)) | set(range(0x6272,0x627A))
    allowed |= set(range(0x6286,0x628C)) | {0x6282,0x6283,0x6298,0x6299}
    allowed |= set(range(OUTPUT,OUTPUT+512)) | set(range(0xB800,0xB880))
    allowed |= set(range(STREAM,STREAM+512))
    allowed |= set(extra_writes)
    # KFIX10 item 2: the scan masks the line it reads, in place, to low
    # ASCII -- the ONLY write the source buffer may take, and only that.
    # ... and only up to and including the LAST terminator (the loop
    # may consume several lines), or the whole buffer when it has none:
    # nothing past it is read, so nothing past it may be written.
    ends = [i for i, byte in enumerate(source) if byte & 0x7F == 13]
    scanned = ends[-1] + 1 if ends and ends[-1] + 1 < len(source) \
        else len(source)
    allowed |= set(range(SOURCE, SOURCE+scanned))
    for i, byte in enumerate(source):
        want = (byte, byte & 0x7F) if i < scanned else (byte,)
        assert mem[SOURCE+i] in want, ('source byte', i)
    assert mem.writes <= allowed, ('writes', sorted(mem.writes-allowed))
    assert bytes(mem[origin:origin+len(code)]) == code
    return mem, stackword(mem,x+1), cpu.processorCycles


def main():
    original = (ROOT / 'src/asm/nas.pla').read_text()
    native = (ROOT / 'src/asm/nasloop.pla').read_text()
    source = source_variant(original,native)
    total, first = 0, None
    for origin in (0x4000,0x41F9):
        tmp, code, entry = assemble(source,FUNCS,origin)
        try:
            assert first is None or first == code, 'native absolute self-reference'
            first = code
            for x in (5,13,30):
                for text, op, emitted in [(' nop',0xEA,b'\xEA'),
                                          (' lda #$7f',0xA9,b'\xA9\x7F'),
                                          (' sta $12',0x85,b'\x85\x12'),
                                          (' inc $1234',0xEE,b'\xEE\x34\x12'),
                                          (' jmp $12',0x4C,b'\x4C\x12\x00'),
                                          (' sta SYM',0x85,b'\x85\x12')]:
                    for phase in (1,2):
                        mem,ret,_ = invoke(code,entry,origin,(text+'\r dfb $00\r').encode(),phase,op,x=x)
                        assert ret == 13,(text,phase,ret)
                        assert word(mem,0x6276)==0x2000+len(emitted)
                        assert word(mem,0x6262 if phase==1 else 0x6264)==1
                        assert mem[STREAM]==op
                        if phase==2:
                            assert bytes(mem[OUTPUT:OUTPUT+len(emitted)])==emitted
                        total+=1
            data = b' lda #$12\r sta $12\r nop\r'*16+b' dfb 0\r'
            replay = bytes.fromhex('a985ea')*16
            expected = bytes.fromhex('a9128512ea')*16
            for phase in (1,2):
                mem,ret,_=invoke(code,entry,origin,data,phase,0xA9,replay=replay)
                assert ret==13 and word(mem,0x6276)==0x2050
                assert word(mem,0x6262 if phase==1 else 0x6264)==48
                assert bytes(mem[STREAM:STREAM+48])==replay
                if phase==2:
                    assert bytes(mem[OUTPUT:OUTPUT+80])==expected
                total+=1
            for count in (511,512):
                mem,ret,_=invoke(code,entry,origin,b' nop\r dfb 0\r',1,0xEA,count=count)
                assert word(mem,0x6262)==512
                assert ret==(13 if count==511 else 0)
                assert word(mem,0x6276)==(0x2001 if count==511 else 0x2000)
                total+=1
            # Exact fallback boundary: parsed once, but not recorded/emitted.
            for phase in (1,2):
                for text,kw in [('LBL nop',{}),(' lda $10+1',{}),
                                (' sta SYM',{'symbol_flags':17}),
                                (' sta SYM',{'symbol_flags':0}),
                                (' sta SYM',{'symbol_zone':2,'zone':1}),
                                (' nop',{'dum':1})]:
                    mem,ret,_=invoke(code,entry,origin,(text+'\r').encode(),phase,0x85,**kw)
                    assert ret==0 and word(mem,0x6276)==0x2000,(phase,text,kw,ret)
                    assert word(mem,0x6262 if phase==1 else 0x6264)==0
                    assert word(mem,0x6232)==len(text)+1
                    assert mem[OUTPUT]==0xA5
                    total+=1
            for text,op,emitted,flags,fix in [
                    (' sta SYM',0x8D,b'\x8D\x12\x80',1,b'\x8F\x01\x00\x12'),
                    (' sta SYM',0x8D,b'\x8D\x00\x80',5,b'\x9F\x01\x00\x12'),
                    (' lda #<SYM',0xA9,b'\xA9\x12',1,b'\x0F\x01\x00\x12'),
                    (' lda #>SYM',0xA9,b'\xA9\x80',1,b'\x4F\x01\x00\x12')]:
                for phase in (1,2):
                    mem,ret,_=invoke(code,entry,origin,(text+'\r dfb 0\r').encode(),phase,op,rel=1,symbol_flags=flags)
                    assert ret==13 and mem[STREAM]==op,(text,phase,ret,mem[STREAM])
                    assert word(mem,0x6276)==0x2000+len(emitted)
                    if phase==2:
                        assert bytes(mem[OUTPUT:OUTPUT+len(emitted)])==emitted
                        assert word(mem,0x6282)==1
                        assert bytes(mem[0xB800:0xB804])==fix
                    total+=1
            for fill in (510,511,512):
                mem,ret,_=invoke(code,entry,origin,b' lda #1\r',2,0xA9,fill=fill)
                if fill==510:
                    assert ret==0xFFFE and word(mem,0x6276)==0x2002
                else:
                    assert ret==0 and word(mem,0x6276)==0x2000 and word(mem,0x6264)==0
                total+=1
            forms = ('', '', '#$12', '$12', '$12,X', '$12,Y',
                     '$1234', '$1234,X', '$1234,Y', '($1234)',
                     '($12,X)', '($12),Y', '($12)', '($1234,X)', '$2002')
            for index, (a,b,c,mode,op,cmos) in enumerate(optab_rows()):
                line = b' '+bytes((a,b,c))+b' '+forms[mode].encode()
                size = MODESIZE[mode]
                value = 0 if mode==14 else (0x1234 if mode in (6,7,8,9,13) else 0x12)
                expected = bytes([op])+value.to_bytes(2,'little')[:size-1]
                for phase in (1,2):
                    for xc in (0,1):
                        mem,ret,_=invoke(code,entry,origin,line+b'\r dfb 0\r',phase,op,
                                         xc=xc,x=5+index%26)
                        fast = phase==2 or (mode in (0,1,2,3,6,14) and (xc or not cmos))
                        if fast:
                            assert ret==13,(line,phase,xc,ret)
                            assert word(mem,0x6276)==0x2000+size
                            assert mem[STREAM]==op
                            if phase==2:
                                assert bytes(mem[OUTPUT:OUTPUT+size])==expected,(line,expected)
                        else:
                            assert ret==0 and word(mem,0x6276)==0x2000,(line,phase,xc,ret)
                        total+=1
            try:
                invoke(code,entry,origin,b' nop\r',1,0xEA,poison=True)
            except AssertionError:
                pass
            else:
                raise AssertionError('sabotage accepted')
        finally:
            tmp.cleanup()
    print(f'PASS: {total} native-loop cases, two-origin identical {len(first)}B closure; no VM, ABI/write guards, fallback and sabotage')


if __name__=='__main__':
    main()
