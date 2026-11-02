#!/usr/bin/env python3
"""Source-bound, full-cycle comparison of cooked NAS replacement and Merlin.

Read-only assembler investigation. Private images; independent byte oracles.
Merlin entries are bound to actual embedded core bytes and native source
signatures. NAS local labels come from ACME, checked against the module.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import tempfile

import profile_nas_paired as paired

pair, hot = paired.pair, paired.hot
ROOT = pair.ROOT


def core_map(binary):
    b1 = (ROOT / 'build/ascore-warm-bank1.obj').read_bytes()
    ac = (ROOT / 'build/ascore-warm-as.obj').read_bytes()
    assert binary.count(b1) == binary.count(ac) == 1
    memory = bytearray(65536)
    memory[0xD000:0xD000+len(b1)] = b1
    memory[0xE5F0:0xE5F0+len(ac)] = ac
    markers = {}
    signatures = {
        'START': 'a2ff9a8675ad00c00a4906',
        'PACK': 'ad2e020a0a0a85eaad2f02',
        'GTLIN': 'a920a01c88992002d0fa8457',
        'CHKOPND': 'a20086f0ad3c02c95c',
        'GETHEX': '9885568555e8bd3c02c95d',
        'DECIMAL': '98888456e6568555bd3c024930c90a',
        'BIN': '188455845626552656e8bd3c02c932',
        'SETOPND': 'a6bb297f9d3c02e040',
        'MAKNUM0': 'a20124ac',
        'GETOPC': 'a2048512841318a000b112',
        'STPT': '861786f2867a86d686d786d1',
    }
    for name, hx in signatures.items():
        sig = bytes.fromhex(hx)
        hits = [base+m.start() for base,data in ((0xD000,b1),(0xE5F0,ac))
                for m in re.finditer(re.escape(sig),data)]
        assert len(hits)==1, (name,hits)
        markers[name]=hits[0]
    for name, at, sig in [('FINDLAB',0xE5F0,'b886d2bd8002c93a'),
                           ('ASM',0xE5F3,None),
                           ('PRCODE',0xE5F6,'a602'),
                           ('CHOP',0xE5F9,'a90085fd858e858d858a')]:
        assert memory[at]==0x4C
        ptr=memory[at+1]+256*memory[at+2]
        if sig: assert memory[ptr:ptr+len(bytes.fromhex(sig))]==bytes.fromhex(sig)
        markers[name]=ptr
    # Remaining source anchors contain branch distances / absolute labels;
    # bind every fixed opcode/operand and require a unique byte match.
    patterns={
        'GTSRC': rb'\xa1\xbc\x29\x7f\xe6\xbc\xd0.\xe6\xbd\xc9\x0d',
        'LIST': rb'\x24\xf2\x30.\xa5\x17\x25\xe9\xd0.',
        'BRACKET': rb'\x24\x19\x30.\xc9\xdd\xd0.',
        'GETCODE': rb'\xbd..\xa0\x02\x31\x12\xf0.\xc8\xb1\x12\xca',
        'PRNTLIN': rb'\xa5\x02\xf0.\x24\xd3\x30.\x20..\x90.',
        'BYTPRN': rb'\x20..\x20\x33\xe0\xe2\xf9\xf4\xe5\xf3',
        'SYMBOL': bytes([0x20,markers['FINDLAB']&255,markers['FINDLAB']>>8])+rb'\x98\xf0.\x20',
        'LUP': rb'\x20..\x05\x56\xd0.\xa9\x80\x85\x7a\x85\x17',
    }
    for name, pattern in patterns.items():
        hits=[base+m.start() for base,data in ((0xD000,b1),(0xE5F0,ac))
              for m in re.finditer(pattern,data,re.S)]
        assert len(hits)==1,(name,hits)
        markers[name]=hits[0]
    lo,hi=paired.as_lookup_range(ROOT/'build',binary)
    markers['NXOPS']=lo
    ranges=[(lo,hi,'opcode-lookup'),
            (markers['GETCODE'],markers['PRCODE'],'opcode-encode'),
            (markers['PRCODE'],lo,'emit-and-PC'),
            (markers['GTLIN'],markers['BYTPRN'],'line-reader'),
            (markers['GTSRC'],markers['MAKNUM0'],'line-reader-helper'),
            (markers['SETOPND'],markers['LUP'],'operand-copy/substitution'),
            (markers['CHKOPND'],markers['CHOP'],'expression-prefix'),
            (markers['CHOP'],markers['CHOP']+0xA0,'expression-control'),
            (markers['BIN'],markers['SYMBOL'],'numeric/literal'),
            (markers['SYMBOL'],0xD000+len(b1),'symbol-value'),
            (markers['MAKNUM0'],markers['LIST'],'immediate/selector')]
    # CHOP ends at JOD's JMP: derive the boundary from the actual branch
    # target of the following MULTEN's fixed source prefix.
    sig=bytes.fromhex('a90a8550a900')
    hits=[m.start() for m in re.finditer(re.escape(sig),b1)]
    assert len(hits)==1
    ranges=[(a,0xD000+hits[0] if n=='expression-control' else b,n) for a,b,n in ranges]
    assert all(a<b for a,b,_ in ranges),ranges
    return memory,markers,ranges


def nas_labels(snapshot,info):
    path=snapshot/'labels.txt'
    asm=(snapshot/'nas.a').read_text()
    expanded=[]; macro_names=[]; in_macro=False
    for line in asm.splitlines():
        if line.lstrip().startswith('!macro '):in_macro=True
        match=re.search(r'\+(NL\w+|NV\w+)\b',line)
        if match and not in_macro and not line.lstrip().startswith(';'):
            i=len(macro_names);macro_names.append(match[1])
            expanded.extend([f'PERF{i}',line,f'PERFEND{i}'])
        else: expanded.append(line)
        if in_macro and line.strip()=='}':in_macro=False
    (snapshot/'profile-labels.a').write_text('\n'.join(expanded)+'\n')
    subprocess.run(['acme','--setpc','8190','-l',str(path),'-o',str(snapshot/'label-check.mod'),
                    str(snapshot/'profile-labels.a')],check=True)
    assert (snapshot/'label-check.mod').read_bytes()==(snapshot/'nas.mod').read_bytes()
    syms={k:int(v,16) for k,v in re.findall(r'([\w]+)\s*=\s*\$([0-9a-fA-F]+)',path.read_text())}
    tag=re.search(r'^(_D\d+)\s+[^\n]*; g_mnemptr',asm,re.M)[1]
    spans=[(info[5]+syms[f'PERF{i}']-0x2000,info[5]+syms[f'PERFEND{i}']-0x2000,n)
           for i,n in enumerate(macro_names)]
    # The old report parser misses initial instructions inside ACME macros.
    # Bind entries to actual labels, not the first non-macro report row.
    starts={syms[label]-0x2000:name for label,name in
            re.findall(r'^(_A\d+)\s+;\s*(\w+)\(\)',asm,re.M)}
    ordered=sorted(starts)
    native=[(lo,ordered[i+1] if i+1<len(ordered) else info[1][0][0],starts[lo])
            for i,lo in enumerate(ordered)]
    assert all(lo<hi for lo,hi,_ in native)
    return {n:info[5]+syms[n]-0x2000 for n in ('NRREAD','NRSTART',tag)},tag,spans,native


def summarize(lines):
    result={}
    for key,rows in sorted(lines.items()):
        result[key]={'count':len(rows)}
        for field in ('cycles','process','kernel'):
            values=[r[field] for r in rows]
            result[key][field]={'sum':sum(values),'mean':statistics.mean(values),
                                'median':statistics.median(values),'min':min(values),'max':max(values)}
        result[key]['buckets']=dict(sum((r['buckets'] for r in rows),Counter()))
    return result


def analyzer(tool,core,markers,ranges,nlabels,ptrtag,spans, lean_fixture=True):
    def analyze(path,initial,final,bank,info):
        cooked,defs,seglen,native,vm,base,_=info
        state={k:initial[k] for k in ('RAMRD','RAMWRT','ALTZP','ramworks_bank')}
        shadow=bytearray(65536)
        entries={base+lo:'native:'+name for lo,_,name in native}
        owners=['kernel/other']*65536
        for a in range(0x800,0xBF00): owners[a]='native:runtime/thunks'
        if any(name=='initloop' for _,_,name in native):
            for a in range(0x70,0x8E):owners[a]='native:call-gates'
        for lo,hi,name in native:
            for a in range(base+lo,base+hi):owners[a]='native:'+name
        for a in list(range(vm['DINTRP'],vm['START']))+list(range(0xEF,0xF9)):owners[a]='VM'
        for off,_,name in defs:
            sig=bytes((0x20,0x06,0x08))+(base+off).to_bytes(2,'little')
            at=cooked.find(sig)
            assert at>=0 and cooked.find(sig,at+1)<0,name
            entries[at+0x800]='VM:'+name
        if tool=='as':
            entries={at:name for name,at in markers.items()}
            owners=['kernel/other']*65536
            for a in range(0x800,0xBF00):owners[a]='frontend/runtime'
            for a in range(0xD000,0xFF00):owners[a]='core:control/other'
            for lo,hi,name in ranges:
                for a in range(lo,hi):owners[a]='core:'+name
        calls=defaultdict(Counter); totals=Counter(); phasecycles=Counter()
        phasebuckets=defaultdict(Counter); macrototals=Counter()
        macroowners={a:n for lo,hi,n in spans for a in range(lo,hi)}
        phase='startup'; previous_sync=False; previous_pc=None; fetches=0
        executed=0; first=last=None; line=None; lines=defaultdict(list)
        corecalls=Counter(); lineend=markers['START'] if tool=='as' else nlabels['NRREAD']
        lineclass=markers['PACK'] if tool=='as' else nlabels['NRSTART']
        rows=0
        with path.open() as stream:
            assert stream.readline().strip().split(',')==['cyc','pc','a','x','y','p','s','addr','rw','data','sync']
            for raw in stream:
                cells=raw.rstrip().split(',')
                cycle=int(cells[0]);pc=int(cells[1],16);addr=int(cells[7],16)
                rw=cells[8];value=int(cells[9],16)
                if first is None:first=cycle
                if last is not None:assert cycle==last+1,'trace gap'
                last=cycle;rows+=1
                active=state['ramworks_bank']==bank and state['RAMRD'] and state['ALTZP']
                if previous_sync:assert addr==previous_pc and rw=='R','fetch alignment'
                if previous_sync and pc==(addr+1)&65535:
                    fetches+=1
                    if active:
                        executed=addr
                        if addr in entries:
                            name=entries[addr]
                            if tool=='nas' and name in ('VM:pass0','VM:pass1','VM:pass2'):phase=name[3:]
                            if tool=='as' and name=='STPT':phase='pass'+str(shadow[2]+1)
                            calls[phase][name]+=1
                            corecalls[name]+=1
                            if line:line['calls'][name]+=1
                        if addr==lineend:
                            if line and line['op'] in ('LDA','STA','INC','NOP'):
                                lines[line['phase']+':'+line['op']].append(line)
                                if not line['calls']['VM:srcslow']:
                                    lines['no-refill:'+line['phase']+':'+line['op']].append(line)
                            line={'phase':phase,'op':None,'cycles':0,'process':0,'kernel':0,'buckets':Counter(),'calls':Counter()}
                        if addr==lineclass:
                            if tool=='as': p=0x22E
                            else:
                                at=nlabels[ptrtag];p=shadow[at]+256*shadow[at+1]
                            op=bytes(c&127 for c in shadow[p:p+3]).decode('ascii').upper()
                            assert line is not None,(tool,phase,op)
                            line['op']=op
                bucket=owners[executed] if active else 'kernel/other'
                if tool=='nas' and bucket=='VM':
                    ip=shadow[0xF2]+256*shadow[0xF3]+int(cells[4],16)
                    owner=hot.symbols.classify_offset(defs,seglen,(ip&65535)-base)
                    bucket='VM:'+(owner or 'runtime')
                totals[bucket]+=1;phasecycles[phase]+=1
                phasebuckets[phase][bucket]+=1
                if tool=='nas' and active and executed in macroowners:
                    macrototals[macroowners[executed]]+=1
                if line:
                    line['cycles']+=1
                    line['process' if active else 'kernel']+=1
                    line['buckets'][bucket]+=1
                if rw=='W':
                    target=state['ramworks_bank']==bank
                    if target and ((addr<0x200 and state['ALTZP']) or (0x200<=addr<0xC000 and state['RAMWRT'])):
                        shadow[addr]=value
                    if addr==0xC073:state['ramworks_bank']=value
                    elif addr in (0xC002,0xC003):state['RAMRD']=addr==0xC003
                    elif addr in (0xC004,0xC005):state['RAMWRT']=addr==0xC005
                    elif addr in (0xC008,0xC009):state['ALTZP']=addr==0xC009
                previous_sync=cells[10]=='1';previous_pc=pc
        assert state=={k:final[k] for k in state},(state,final)
        assert sum(totals.values())==rows
        summary=summarize(lines)
        if lean_fixture:
            for p in ('pass1','pass2'):
                for op in ('LDA','STA','INC','NOP'):
                    assert summary[p+':'+op]['count']==100,(tool,p,op,summary)
        else:
            assert tool == 'nas' and calls['pass1']['VM:pass1'] == 1
            assert calls['pass2']['VM:pass2'] == 1 and 'pass0' not in phasecycles
        return {'rows':rows,'opcode_fetches':fetches,'phase_cycles':dict(phasecycles),
                'calls':dict(corecalls),'calls_by_phase':dict(calls),'cycle_buckets':dict(totals),
                'phase_buckets':dict(phasebuckets),'macro_cycles':dict(macrototals),
                'instructions':summary,
                'note':'Each line interval begins before reading and ends at the next line read; includes intervening VM/services/IRQ. VM function owner is IP/Y-based and approximate; line and process totals are full-cycle counts.'}
    return analyze


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir',type=Path,default=ROOT/'build')
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--tool',choices=('as','nas','both'),default='both')
    args=ap.parse_args()
    args.build_dir=args.build_dir.resolve()
    assembler=(ROOT/'build/as.bin').read_bytes();nas=(args.build_dir/'nas.cut').read_bytes()
    core,markers,ranges=core_map(assembler)
    report={'method':__doc__,'nas_sha256':pair.digest(nas),'as_sha256':pair.digest(assembler),
            'as_markers':markers,'as_ranges':ranges,'tools':{},
            'image_sha256':pair.digest((ROOT/'build/profile.po').read_bytes()),
            'supervisor_sha256':pair.digest(Path(pair.rig.SUPERVISOR).read_bytes())}
    report['source_sha256']={str(p.relative_to(ROOT)):pair.digest(p.read_bytes()) for p in
        [ROOT/'build/merlin_patched_warm/ASSMAIN.S',ROOT/'build/merlin_patched_warm/ASS.BNK1.S',
         ROOT/'vendor/merlin/GETLINE.S',ROOT/'vendor/merlin/BRACKET.S',args.build_dir/'nas.a']}
    with tempfile.TemporaryDirectory(prefix='nas-merlin-paths-') as temp:
        tmp=Path(temp)
        for n in hot.ARTIFACTS:shutil.copyfile(args.build_dir/n,tmp/n)
        info=hot.symbolize(tmp);nlabels,ptrtag,spans,native=nas_labels(tmp,info)
        info=info[:3]+(native,)+info[4:]
        report['nas_markers']=nlabels
        template=tmp/'template.po';shutil.copyfile(ROOT/'build/profile.po',template)
        case,name,source=pair.FIXTURES[-1]
        expected=pair.merlin_oracle(source)
        report['fixture_sha256']=pair.digest(source.read_bytes())
        report['object_sha256']=pair.digest(expected)
        v=pair.prodos.mount(str(template))
        try:
            pair.prodos.mkdir(pair.DIRECTORY)
            for n,data in (('NAS',nas),('ASX',assembler)):
                pair.prodos.write(f'{pair.DIRECTORY}/{n}',data,file_type=6,aux_type=0x800)
            pair.prodos.write(f'{pair.DIRECTORY}/{name}',pair.convert.text_from_host(source.read_bytes()),file_type=4)
        finally:pair.prodos.unmount(v)
        astable=paired.as_symbols(ROOT/'build',assembler)
        for tool in ('as','nas') if args.tool=='both' else (args.tool,):
            disk=tmp/(tool+'.po');shutil.copyfile(template,disk)
            print('Tracing '+tool,flush=True)
            report['tools'][tool]=paired.run(disk,tool,name,expected,info,assembler,astable,2718,
                tmp/(tool+'.csv'),analyzer(tool,core,markers,ranges,nlabels,ptrtag,spans))
            args.output.write_text(json.dumps(report,indent=2)+'\n')
            print(tool+' trace/bytes/counts PASS',flush=True)
    print('PASS: full trace, 100 of each opcode in each pass, cold/warm fresh-merlin32 bytes')


if __name__=='__main__':main()
