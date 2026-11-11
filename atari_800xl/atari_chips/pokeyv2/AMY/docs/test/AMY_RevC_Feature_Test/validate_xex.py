#!/usr/bin/env python3
"""Dependency-free limited 6502 instruction-level validator for the generated .XEX.
It simulates the OS VBI clock and AMY register writes, NOT the AMY audio or FPGA.
"""
import sys, struct, json, pathlib
ROOT=pathlib.Path(__file__).resolve().parent
F=ROOT/'release/AMY_FEATURE_TEST.xex'
data=F.read_bytes()
assert data[:2]==b'\xff\xff'
lo,hi=struct.unpack_from('<HH',data,2)
pos=6
assert lo==0x4000
mem=bytearray(65536)
mem[lo:hi+1]=data[pos:pos+hi-lo+1]
pos+=hi-lo+1
assert struct.unpack_from('<HHH',data,pos)==(0x2E0,0x2E1,0x4000)

# reverse limited source assembler opcodes
MODES={
0xA9:('LDA','imm'),0xA5:('LDA','zp'),0xAD:('LDA','abs'),0xBD:('LDA','absx'),0xB1:('LDA','indy'),
0xA2:('LDX','imm'),0xA6:('LDX','zp'),0xAE:('LDX','abs'),0xA0:('LDY','imm'),
0x85:('STA','zp'),0x8D:('STA','abs'),0x9D:('STA','absx'),0x86:('STX','zp'),0x8E:('STX','abs'),
0x29:('AND','imm'),0x25:('AND','zp'),0x2D:('AND','abs'),
0xC9:('CMP','imm'),0xC5:('CMP','zp'),0xCD:('CMP','abs'),
0xE0:('CPX','imm'),0x2C:('BIT','abs'),0x24:('BIT','zp'),
0x38:('SEC','impl'),0xE9:('SBC','imm'),0xE5:('SBC','zp'),0xED:('SBC','abs'),
0x0A:('ASL','acc'),0xE6:('INC','zp'),0xEE:('INC','abs'),
0xF0:('BEQ','rel'),0xD0:('BNE','rel'),0x30:('BMI','rel'),0x90:('BCC','rel'),0xB0:('BCS','rel'),0x70:('BVS','rel'),0x50:('BVC','rel'),
0x4C:('JMP','abs'),0x20:('JSR','abs'),0x60:('RTS','impl'),0xAA:('TAX','impl'),0x8A:('TXA','impl'),0x48:('PHA','impl'),0x68:('PLA','impl'),0xEA:('NOP','impl'),0x58:('CLI','impl')
}

class Emulator:
    def __init__(self,pal):
        self.pal=pal; self.A=self.X=self.Y=0;self.C=self.V=self.N=self.Z=0
        self.SP=0xFF;self.PC=0x4000;self.counter=0;self.ticks=0;self.finished=False
        self.writes=[];self.vol_events=[]
        self.mute_time=None;self.max_gap_setup=0
        self.put(0xD014,0x0E if pal else 0)
        # End-of-entry sentinel for RTS.
        self.push(0xFF);self.push(0xFF)
    def get(self,addr):
        if addr==0x14:return self.ticks&0xFF
        if addr in (0xD2C0,0xD2CE):return 0
        return mem[addr]
    def put(self,addr,v):
        v&=255
        if addr==0xD2C6:
            if v!=0 or (self.vol_events and self.vol_events[-1][1]!=0):
                self.vol_events.append((self.ticks,v,mem[0x82]))
        if 0xD2C0<=addr<=0xD2CF:
            self.writes.append((self.ticks,mem[0x82],addr-0xD2C0,v))
        mem[addr]=v
    def push(self,v):self.put(0x100+self.SP,v);self.SP=(self.SP-1)&255
    def pop(self):self.SP=(self.SP+1)&255;return self.get(0x100+self.SP)
    def nz(self,v):self.Z=int(v&255==0);self.N=int(bool(v&128))
    def step(self):
        self.counter+=1
        if self.counter%2000==0:self.ticks+=1
        op=self.get(self.PC)
        if op not in MODES:raise AssertionError((hex(self.PC),hex(op)))
        mn,md=MODES[op];pc=self.PC
        mode_len={'impl':1,'acc':1,'imm':2,'zp':2,'rel':2,'abs':3,'absx':3,'indy':2}[md]
        self.PC=(pc+mode_len)&0xffff
        if md in ('imm','zp','rel'): arg=self.get(pc+1)
        elif md in ('abs','absx'):arg=self.get(pc+1)|(self.get(pc+2)<<8)
        else:arg=0
        if md=='absx':arg=(arg+self.X)&65535
        if md=='indy':arg=(self.get(self.get(pc+1))+(self.get((self.get(pc+1)+1)&255)<<8)+self.Y)&65535
        if md=='zp':addr=arg;val=self.get(addr)
        elif md in ('abs','absx','indy'):addr=arg;val=self.get(addr)
        else:val=arg
        if mn=='LDA':self.A=val;self.nz(self.A)
        elif mn=='LDX':self.X=val;self.nz(self.X)
        elif mn=='LDY':self.Y=val;self.nz(self.Y)
        elif mn=='STA':self.put(addr,self.A)
        elif mn=='STX':self.put(addr,self.X)
        elif mn=='AND':self.A&=val;self.nz(self.A)
        elif mn in ('CMP','CPX'):
            d=(self.A if mn=='CMP' else self.X)-val
            self.C=int(d>=0);self.nz(d)
        elif mn=='BIT':
            self.Z=int((self.A&val)==0);self.N=int(bool(val&128));self.V=int(bool(val&64))
        elif mn=='ASL':self.C=int(bool(self.A&128));self.A=(self.A<<1)&255;self.nz(self.A)
        elif mn=='INC':self.put(addr,val+1);self.nz((val+1)&255)
        elif mn=='SEC':self.C=1
        elif mn=='SBC':
            d=self.A-val-(1-self.C);r=d&255
            self.C=int(d>=0);self.V=int(bool(((self.A^val)&(self.A^r)&128)))
            self.A=r;self.nz(r)
        elif mn=='JMP':self.PC=arg
        elif mn=='JSR':
            ret=(pc+2)&65535
            self.push(ret>>8);self.push(ret&255);self.PC=arg
        elif mn=='RTS':
            self.PC=(((self.pop()|(self.pop()<<8))+1)&65535)
            if self.PC==0:self.finished=True
        elif mn=='TAX':self.X=self.A;self.nz(self.X)
        elif mn=='TXA':self.A=self.X;self.nz(self.A)
        elif mn=='PHA':self.push(self.A)
        elif mn=='PLA':self.A=self.pop();self.nz(self.A)
        elif mn=='CLI':pass
        elif mn=='NOP':pass
        elif mn in ('BEQ','BNE','BMI','BCC','BCS','BVS','BVC'):
            take={'BEQ':self.Z==1,'BNE':self.Z==0,'BMI':self.N==1,'BCC':self.C==0,
                  'BCS':self.C==1,'BVS':self.V==1,'BVC':self.V==0}[mn]
            if take:self.PC=(self.PC+(arg if arg<128 else arg-256))&65535
        else:raise ValueError(mn)

for pal in [True,False]:
    # Regenerate RAM because emulator writes into the code's global mem.
    mem[:]=bytes(65536)
    mem[lo:hi+1]=data[6:6+hi-lo+1]
    em=Emulator(pal)
    for _ in range(14_000_000):
        em.step()
        if em.finished:break
    assert em.finished,(pal,em.PC,em.counter,em.ticks)
    on=[x for x in em.vol_events if x[1]!=0]
    off=[x for x in em.vol_events if x[1]==0]
    assert len(on)==37,(pal,len(on),on)
    assert len(off)==37,(pal,len(off))
    print('PAL' if pal else 'NTSC','instructions',em.counter,'frames',em.ticks,
          'first_on',on[0],'last_on',on[-1],'last_off',off[-1])
    print('frame differences', [(on[i+1][0]-on[i][0]) for i in range(5)])
    print('durations',[(off[i][0]-on[i][0]) for i in range(5)])
    assert all((on[i+1][0]-on[i][0]) in (30 if pal else 36, 31 if pal else 37) for i in range(36))
    assert all((off[i][0]-on[i][0]) in (25 if pal else 30, 26 if pal else 31) for i in range(37))
    # every segment command stream reset, and unlocked command programming seen for corresponding cases.
    writecases={i:[] for i in range(37)}
    for tick,idx,offset,v in em.writes:
        if idx<37:writecases[idx].append((offset,v))
    assert all((0,0) in writecases[i] for i in range(37))
    assert all((7,0xA5) in writecases[i] and (7,0x5A) in writecases[i] for i in range(37) if json.loads((ROOT/'release/MANIFEST.json').read_text())['cases'][i]['ext'])
    assert (15,3) in writecases[14]
print('PASS Atari XEX control-flow, data streams, staged AMY writes and PAL/NTSC frame schedules')
