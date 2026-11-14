#!/usr/bin/env python3
"""Build a deterministic Atari 6502 PokeyMAX AMY Rev C audio test .XEX.

Self-contained two-pass assembler for the deliberately small 6502 source subset
used by this generator, avoiding an external assembler dependency.
"""
from __future__ import annotations
import csv, json, math, re, struct, pathlib, collections
ROOT = pathlib.Path(__file__).resolve().parent
OUT = ROOT / 'release'
OUT.mkdir(exist_ok=True)
CLK=8192000
AMY=0xD2C0
VOLUME=AMY+6
# All sounds start from 8.192 MHz corrected A440 tone code.
A440=0x1372
pitch=lambda st: max(0,min(8191,A440+round(st*64)))
# Atari noise generator RAM initialization, consistent with the amyconv source.
NOISE_GENS = [dict(a=0x1234, b=0x4D2B, c=0x7A11, ud=0, bb=0, s=0x80F),
              dict(a=0x6E5F, b=0x0F0F, c=0x3333, ud=0, bb=0, s=0x80F)]
noise_image=[0]*64
for g,d in enumerate(NOISE_GENS):
    for i in range(15):
        noise_image[(14-i)*2+g]=(((d['a']>>i)&1)<<2)|(((d['b']>>i)&1)<<1)|((d['c']>>i)&1)
    for i in range(12):
        noise_image[(20+i)*2+g]=(((d['ud']>>i)&1)<<2)|(((d['bb']>>i)&1)<<1)|((d['s']>>i)&1)

# (name, type0, harmonics, config flags) - explicitly bounded functional coverage.
# C0=baseline=one harmonic; B8=moderate level, and moderate gain at wrapper ($20).
C=[]
def add(group,name,**kw):
    d=dict(group=group,name=name,voice_type=0,harmonics=1,mode40=False,
           level=0xC0,pitch=pitch(0),voice1=False,stereo=False,
           attack=False,decay=False,glide=0,gain=0x20,
           ext=False,atten=0,detune=0,diffusion=0,white=False,engine=False,
           extra_noise=False,locked_type3=False)
    d.update(kw); C.append(d)
# Core features: source types, envelope behaviour, 40/64, stereo, gain, engine.
add('CORE','Pure sine / reference A440')
add('CORE','Two harmonics', harmonics=2)
add('CORE','Eight harmonics', harmonics=8)
add('CORE','Harmonic amplitude attack', attack=True, harmonics=1)
add('CORE','Harmonic amplitude decay', decay=True, harmonics=1)
add('CORE','Frequency glide up', glide=1, harmonics=1)
add('CORE','Frequency glide down', glide=-1, harmonics=1)
add('CORE','Original noise generator 0', voice_type=1, harmonics=6, pitch=pitch(18), level=0xB8)
add('CORE','Original noise generator 1', voice_type=2, harmonics=6, pitch=pitch(18), level=0xB8)
add('CORE','40-harmonic mode', mode40=True, harmonics=4)
add('CORE','64-harmonic mode control', mode40=False, harmonics=4)
add('CORE','Global output volume half', gain=0x10)
add('CORE','Stereo independent voices', voice1=True, stereo=True, harmonics=2)
add('CORE','Tonal plus original noise', voice1=True, extra_noise=True, harmonics=2)
add('CORE','6502 note engine note-on',engine=True)
# Extension-alone variants and unlocked/disabled compatibility control.
add('EXT','Unlocked, all coefficients zero',ext=True)
add('EXT','Type 3 locked (legacy control)',voice_type=3,locked_type3=True,harmonics=6,level=0xB8)
add('EXT','White excitation (type 3)',white=True,ext=True,harmonics=6,pitch=pitch(18),level=0xB8)
add('EXT','Voice attenuation 6 dB',ext=True,atten=24)
add('EXT','Voice attenuation 12 dB',ext=True,atten=48)
add('EXT','Harmonic detune +24/64',ext=True,detune=24,harmonics=4)
add('EXT','Harmonic detune -24/64',ext=True,detune=-24,harmonics=4)
add('EXT','Phase diffusion 24/63',ext=True,diffusion=24,harmonics=4)
add('EXT','Phase diffusion 63/63',ext=True,diffusion=63,harmonics=4)
# Focused interactions rather than combinatorial explosion.
add('COMBO','Attenuation + detune',ext=True,atten=24,detune=24,harmonics=4)
add('COMBO','Attenuation + diffusion',ext=True,atten=24,diffusion=30,harmonics=4)
add('COMBO','Detune + diffusion',ext=True,detune=-24,diffusion=30,harmonics=4)
add('COMBO','White + attenuation',ext=True,white=True,atten=24,harmonics=6,pitch=pitch(18),level=0xB8)
add('COMBO','White + detune',ext=True,white=True,detune=24,harmonics=6,pitch=pitch(18),level=0xB8)
add('COMBO','White + diffusion',ext=True,white=True,diffusion=30,harmonics=6,pitch=pitch(18),level=0xB8)
add('COMBO','Original noise + attenuation',ext=True,voice_type=1,atten=24,harmonics=6,pitch=pitch(18),level=0xB8)
add('COMBO','Stereo + detune',ext=True,stereo=True,voice1=True,detune=24,harmonics=3)
add('COMBO','40-mode + diffusion',ext=True,mode40=True,diffusion=30,harmonics=4)
add('COMBO','40-mode + detune',ext=True,mode40=True,detune=24,harmonics=4)
add('COMBO','Attenuation + detune + diffusion',ext=True,atten=24,detune=-24,diffusion=30,harmonics=4)
add('COMBO','White + attenuation + diffusion',ext=True,white=True,atten=24,diffusion=30,harmonics=6,pitch=pitch(18),level=0xB8)
add('COMBO','All four extensions',ext=True,white=True,atten=24,detune=24,diffusion=30,harmonics=6,pitch=pitch(18),level=0xB8)

# Record pairs (address offset,value) or special interpreter sentinels:
#  0xFE = wait for AMY idle ; 0xFD = wait for engine idle ; 0xFF = stream end.
FE=0xFE; FD=0xFD; END=0xFF
class Script:
    def __init__(self): self.b=[]
    def w(self,addr,val):
        assert 0<=addr<=15 and 0<=val<=255
        self.b += [addr,val]
    def idle(self):self.b.append(FE)
    def eng_idle(self):self.b.append(FD)
    def cmd(self,command,a=None,b=None,c=None):
        if a is not None:self.w(1,a&255)
        if b is not None:self.w(2,b&255)
        if c is not None:self.w(3,c&255)
        self.w(0,command)
    def pitch(self,v,word,sl=0):self.cmd(0x08+v,sl,(word>>8)&31,word&255)
    def amp(self,h,level,sl=0):self.cmd(0x40+h,sl,None,level)
    def extcmd(self,code,index,value):
        self.cmd(code,index,0,value)
        self.idle()
    def memwrite(self,addr,word):
        self.w(12,addr)
        for k in range(3):self.w(8+k,word>>(8*k)&255)
        self.w(13,(word>>24)&255)
        self.eng_idle()

def script_for(d):
    s=Script()
    # Each test is self-contained: reset, mute, normal hardware initialization.
    s.w(6,0)
    s.w(15,0)              # disable optional note engine between tests
    s.w(0,0)                # reset: clears extension lock and RAM state
    s.idle()
    s.w(4,255);s.w(5,255)
    # SOR: INDIVIDUAL voice sample; 40/64 selector.
    s.w(0,0x2C if d['mode40'] else 0x24)
    for v in range(8):
        t=(d['voice_type'] if v==0 else (1 if d['extra_noise'] and v==1 else 0))
        if v==0 and d['white']:t=3
        s.cmd(0x10+v,a=t)
    # Start with all harmonics definitely silent.
    s.w(1,0);s.w(3,0)
    for h in range(64):s.w(0,0x40+h)
    # 8 x 8 harmonic allocation (the final pair of each group of four pairs).
    for p in range(32):s.w(0,0x80+2*p+(1 if p%4==3 else 0))
    # Load both original PRBS generators before leaving NZINIT.
    s.w(0,0x33)
    for a,x in enumerate(noise_image):
        s.w(1,x);s.w(0,0x80+a)
    s.w(0,0x31)
    s.idle()
    # Unlock only when explicitly requested: handshake needs an idle FIFO.
    if d['ext']:
        s.w(7,0xA5)
        s.w(7,0x5A)
        # coeff reset clears all existing params, does not lock.
        s.cmd(0x39)
        s.idle()
        if d['atten']:s.extcmd(0x34,0,d['atten'])
        if d['detune']:
            # Distribute deliberately on harmonics 0..3, to expose spectral shift.
            for h in range(min(d['harmonics'],4)):
                s.extcmd(0x35,h,d['detune']&63)
        if d['diffusion']:
            for h in range(min(d['harmonics'],4)):
                s.extcmd(0x36,h,d['diffusion']&63)
    if d['stereo']:
        s.w(4,1);s.w(5,2)
    if d['engine']:
        # Note engine uses one instrument (0), voice 0, pitch note-0 code $0132.
        # 32+voice state: default inactive instrument 0 selector (bit4).
        s.w(15,3)           # engine enabled, 8 voices x 8 slots
        s.memwrite(40,0x0132)
        s.memwrite(32,0x00000010)
        # Instrument 0 header: no glide, no decay, release slope $9D.
        s.memwrite(48,0x0000009D)
        for h in range(8):
            # little-endian level offset, attack, decay, sustain offset
            # C0 is achieved by W1=C0 and level-offset=0.
            ofs= (0 if h==0 else (12 if h==1 else 255))
            s.memwrite(64+h,(0xFF<<24) | ofs)
        # W0=note 64 -> pitch 0132 + $1000 = $1132 (C4); W1=C0, W2=2.
        s.w(8,64);s.w(9,0xC0);s.w(10,2);s.w(11,0x90)
        s.eng_idle()
    else:
        main_pitch=d['pitch']
        if d['glide']<0: main_pitch=pitch(0)  # down from A4 to C4
        elif d['glide']>0: main_pitch=pitch(-9) # up from C4 to A4
        s.pitch(0,main_pitch)
        if d['voice1']:
            s.pitch(1,pitch(-5))
        level=d['level']
        num=d['harmonics']
        for h in range(num):
            # decrease every harmonic ~5 dB for tonal sounds, near-flat for noise.
            base=level - ((h*13) if d['voice_type']==0 and not d['white'] else h*2)
            if base<0x20:base=0x20
            if d['attack']:
                # Initially silent; then approach target with a rising slope.
                s.amp(h,0)
                s.amp(h,base,sl=0x2F)
            elif d['decay']:
                s.amp(h,base)
                s.amp(h,0,sl=0xB1)
            else:
                s.amp(h,base)
        if d['glide']>0:
            s.pitch(0,pitch(0),sl=0x03)
        elif d['glide']<0:
            s.pitch(0,pitch(-9),sl=0x9D)
        if d['voice1']:
            for h in range(num):
                s.amp(h+8,max(0x30,0xB8-h*13))
    s.idle()
    s.b.append(END)
    return s.b

SCRIPTS=[script_for(d) for d in C]

# Human-readable data and runtime source: .org / .byte / .word / absolute 6502.
# Tiny assembler below builds this without any external cc65/MADS dependency.
HEAD=f'''; AMY Rev C self-contained 6502 audio feature test. Generated by create_test.py.
; Atari executable .XEX; start at $4000, no BASIC or CIO required.
; Each case produces 0.5s of audio followed by 0.1s of silence.
; PAL 50Hz: 25 + 5 video frames; NTSC 60Hz: 30 + 6 frames.
; Uses OS RTCLOK low byte ($14) for timing; do not disable VBI/IRQ.
; Read full test list and nominal timing in MANIFEST.csv.
; Uses 8.192MHz Rev C AMY, 8 voices x 8 harmonics, $D2C0-$D2CF.
;
.org $4000
AMY = $D2C0
VOL = $D2C6
EC_STATUS = $D2CE
RTCLOK_LO = $0014
PALREG = $D014
PTRLO = $0080
PTRHI = $0081
INDEX = $0082
N_ON = $0083
N_GAP = $0084
N_LEAD = $0085
START_FRAME = $0086
GAP_FRAME = $0087
DURATION = $0088

ENTRY:
    LDA #$00
    STA VOL
    STA INDEX
    ; PALREG bits 1-3 nonzero = PAL machine, as in amyconv.
    LDA PALREG
    AND #$0E
    BEQ NTSC_MODE
PAL_MODE:
    LDA #$19        ; 25 frames = 0.5 second PAL
    STA N_ON
    LDA #$05
    STA N_GAP
    LDA #$32        ; 50 frames lead in = 1 second
    STA N_LEAD
    JMP SETUP_FIRST
NTSC_MODE:
    LDA #$1E        ; 30 frames = 0.5 second NTSC
    STA N_ON
    LDA #$06
    STA N_GAP
    LDA #$3C
    STA N_LEAD
SETUP_FIRST:
    JSR EXEC_SCRIPT
    LDA N_LEAD
    JSR WAIT_FRAMES
PLAY_CASE:
    ; Frame alignment makes section times deterministic to one video frame.
    LDA RTCLOK_LO
ALIGN:
    CMP RTCLOK_LO
    BEQ ALIGN
PLAY_NOALIGN:
    LDX INDEX
    LDA CASE_GAIN,X ; default $20, half-level diagnostic $10
    STA VOL
    LDA N_ON
    JSR WAIT_FRAMES
    LDA #$00
    STA VOL         ; immediate mute, even if a release envelope continues
    INC INDEX
    LDA INDEX
    CMP #NUM_CASES
    BEQ FINISH
    LDA RTCLOK_LO
    STA GAP_FRAME
    JSR EXEC_SCRIPT  ; reprogram AMY inside the silent interval
    LDA GAP_FRAME
    STA START_FRAME
    LDA N_GAP
    JSR WAIT_FROM_START
    JMP PLAY_NOALIGN
FINISH:
    ; Final silence, then return to DOS if it installed a RUN vector.
    LDA #$00
    STA VOL
    LDA N_GAP
    JSR WAIT_FRAMES
    RTS

WAIT_FRAMES:
    ; Input A = number of video frames to wait from now.
    PHA
    LDA RTCLOK_LO
    STA START_FRAME
    PLA
WAIT_FROM_START:
    ; Input A = frames; START_FRAME set by caller.
    STA DURATION
WAIT_LOOP:
    LDA RTCLOK_LO
    SEC
    SBC START_FRAME
    CMP DURATION
    BCC WAIT_LOOP
    RTS

EXEC_SCRIPT:
    ; Find the indexed script pointer.
    LDA INDEX
    ASL A
    TAX
    LDA CASE_PTRS,X
    STA PTRLO
    LDA CASE_PTRS+1,X
    STA PTRHI
CMD_LOOP:
    JSR NEXT_BYTE
    CMP #$FF
    BEQ SCRIPT_END
    CMP #$FE
    BEQ SCRIPT_AMY_IDLE
    CMP #$FD
    BEQ SCRIPT_ENG_IDLE
    TAX              ; destination offset 0..15
    JSR NEXT_BYTE    ; A = value
    CPX #$04
    BCS WRITE_NOW
FIFO_WAIT:
    ; BIT loads V with status bit6 = FIFO full.
    BIT AMY
    BVS FIFO_WAIT
WRITE_NOW:
    STA AMY,X
    JMP CMD_LOOP
SCRIPT_AMY_IDLE:
    JSR WAIT_AMY_IDLE
    JMP CMD_LOOP
SCRIPT_ENG_IDLE:
    JSR WAIT_ENGINE_IDLE
    JMP CMD_LOOP
SCRIPT_END:
    RTS

NEXT_BYTE:
    LDY #$00
    LDA (PTRLO),Y
    INC PTRLO
    BNE BYTE_OK
    INC PTRHI
BYTE_OK:
    RTS
WAIT_AMY_IDLE:
    BIT AMY
    BMI WAIT_AMY_IDLE
    RTS
WAIT_ENGINE_IDLE:
    BIT EC_STATUS
    BMI WAIT_ENGINE_IDLE
    RTS

NUM_CASES = {len(C)}
CASE_PTRS:
'''

S=HEAD+''.join('    .word CASE_%02d\n'%i for i in range(len(C)))+'\nCASE_GAIN:\n'+'    .byte '+','.join('$%02X'%d['gain'] for d in C)+'\n\n'
for i,(d,sc) in enumerate(zip(C,SCRIPTS)):
    S+='; %02d %s: %s\nCASE_%02d:\n'%(i+1,d['group'],d['name'],i)
    for j in range(0,len(sc),20):
        S+='    .byte '+','.join('$%02X'%v for v in sc[j:j+20])+'\n'
    S+='\n'
(OUT/'AMY_FEATURE_TEST.asm').write_text(S)

# Two-pass assembler for generated (no macros) 6502 assembly.
OPC={
'ADC':{'imm':0x69,'zp':0x65,'abs':0x6D}, 'AND':{'imm':0x29,'zp':0x25,'abs':0x2D},
'ASL':{'acc':0x0A}, 'BEQ':{'rel':0xF0}, 'BNE':{'rel':0xD0}, 'BMI':{'rel':0x30},
'BCC':{'rel':0x90},'BCS':{'rel':0xB0},'BVS':{'rel':0x70},'BVC':{'rel':0x50},
'BIT':{'zp':0x24,'abs':0x2C},'CMP':{'imm':0xC9,'zp':0xC5,'abs':0xCD},
'CPX':{'imm':0xE0},'INC':{'zp':0xE6,'abs':0xEE},'JMP':{'abs':0x4C},
'JSR':{'abs':0x20},'LDA':{'imm':0xA9,'zp':0xA5,'abs':0xAD,'absx':0xBD,'indy':0xB1},
'LDX':{'imm':0xA2,'zp':0xA6,'abs':0xAE},'LDY':{'imm':0xA0},
'PHA':{'impl':0x48},'PLA':{'impl':0x68},'RTS':{'impl':0x60},
'STA':{'zp':0x85,'abs':0x8D,'absx':0x9D},'STX':{'zp':0x86,'abs':0x8E},
'TAX':{'impl':0xAA},'TXA':{'impl':0x8A},'SEC':{'impl':0x38},
'SBC':{'imm':0xE9,'zp':0xE5,'abs':0xED},'NOP':{'impl':0xEA},
'CLI':{'impl':0x58}
}
origin=0x4000
lines=[]; labels={}; pc=origin
hexre=re.compile(r'\$([0-9A-Fa-f]+)')
def evalexpr(s,syms):
    s=s.strip()
    if s.startswith('<'):return evalexpr(s[1:],syms)&255
    if s.startswith('>'):return evalexpr(s[1:],syms)>>8&255
    s=hexre.sub(lambda m: '0x'+m.group(1), s)
    return int(eval(s,{'__builtins__':{}},syms))
for no,raw in enumerate(S.splitlines(),1):
    src=raw.split(';',1)[0].strip()
    if not src:continue
    if '=' in src and ':' not in src:
        k,v=src.split('=',1)
        labels[k.strip()]=evalexpr(v,labels)
        continue
    if src.endswith(':'):
        lab=src[:-1];assert lab not in labels,lab
        labels[lab]=pc
        continue
    t=src.split(None,1);op=t[0].upper();arg=t[1].strip() if len(t)>1 else ''
    if op=='.ORG':
        assert pc==origin; assert evalexpr(arg,labels)==origin;continue
    if op in ('.BYTE','.WORD'):
        size=1 if op=='.BYTE' else 2
        exprs=[a.strip() for a in arg.split(',')]
        lines.append((no,pc,op,exprs,size*len(exprs)))
        pc+=size*len(exprs)
        continue
    assert op in OPC,(no,op)
    if not arg:mode='impl'
    elif arg.upper()=='A':mode='acc'
    elif op.startswith('B') and op not in ('BIT',):mode='rel'
    elif arg.startswith('#'):mode='imm';arg=arg[1:]
    elif arg.startswith('(') and arg.endswith('),Y'):mode='indy';arg=arg[1:-3]
    elif arg.endswith(',X'):mode='absx';arg=arg[:-2]
    else:
        # choose absolute for unresolved symbols unless the value known to fit ZP
        try: val=evalexpr(arg,labels)
        except (NameError,SyntaxError): val=0x100
        mode='zp' if val<256 and 'zp' in OPC[op] else 'abs'
    assert mode in OPC[op],(no,op,mode,arg)
    sz=1 if mode in ('impl','acc') else 2 if mode in ('rel','imm','zp','indy') else 3
    lines.append((no,pc,op,(mode,arg),sz));pc+=sz
end=pc
assert end<0xC000, hex(end)
out=bytearray(end-origin);srcmap=[]
for no,pc,op,operand,sz in lines:
    vals=[]
    if op in ('.BYTE','.WORD'):
        for a in operand:
            n=evalexpr(a,labels)
            if op=='.BYTE':assert 0<=n<256,(no,a,n);vals.append(n)
            else:assert 0<=n<=65535;vals.extend([n&255,n>>8])
    else:
        mode,arg=operand
        vals.append(OPC[op][mode])
        if mode in ('impl','acc'):pass
        else:
            n=evalexpr(arg,labels)
            if mode=='rel':
                d=n-(pc+2);assert -128<=d<=127,(no,op,arg,d)
                vals.append(d&255)
            elif sz==2:
                assert 0<=n<=255,(no,op,arg,n);vals.append(n)
            else:vals.extend([n&255,(n>>8)&255])
    assert len(vals)==sz,(no,op,vals,sz)
    out[pc-origin:pc-origin+sz]=bytes(vals)
    srcmap.append((no,pc,vals))
# 6502 .XEX: load entire code at $4000, then RUNAD vector $02E0.
xex=bytearray([0xFF,0xFF])
xex+=struct.pack('<HH',origin,end-1)+out
xex+=struct.pack('<HHH',0x02E0,0x02E1,labels['ENTRY'])
(OUT/'AMY_FEATURE_TEST.xex').write_bytes(xex)

# Schedule audio 0.5 s + gap0.1; PAL/NTSC use corresponding video frames.
with (OUT/'MANIFEST.csv').open('w',newline='') as f:
    writer=csv.writer(f)
    writer.writerow(['segment','group','label','from_first_onset_s','duration_s','gap_s','voice0_type','harmonics','att_quarter_db','detune_sixbit_signed','diffusion_0_63','expected_feature','notes'])
    for i,d in enumerate(C):
        feature=('white ' if d['white'] else '')+('att ' if d['atten'] else '')+('detune ' if d['detune'] else '')+('diffusion ' if d['diffusion'] else '')
        writer.writerow([i+1,d['group'],d['name'],round(i*.6,3),.5,.1,3 if d['white'] else d['voice_type'],d['harmonics'],d['atten'],d['detune'],d['diffusion'],feature.strip() or 'legacy', 'stereo L/R' if d['stereo'] else ''])

(OUT/'MANIFEST.json').write_text(json.dumps({'clock_hz':8192000,'base_address':'$D2C0','initial_silence_s':1,'segment_duration_s':.5,'gap_s':.1,'cases':C},indent=2))
(OUT/'BUILD_INFO.json').write_text(json.dumps({'assembly_origin':f'${origin:04X}','end':f'${end-1:04X}', 'xex_bytes':len(xex),'script_bytes':[len(x) for x in SCRIPTS], 'case_count':len(C), 'pal_frames':{'audio':25,'gap':5,'initial':50},'ntsc_frames':{'audio':30,'gap':6,'initial':60}},indent=2))
# Sanity: verify pointers and declared length and all script termination.
assert len(xex)==2+4+len(out)+6
assert [w for w in C if w['ext'] and w['white']]
for i,sc in enumerate(SCRIPTS):
    assert sc[-1]==0xFF
    # Each script starts with mute and explicit reset, and never includes 0xFF as an address
    assert sc[:6]==[6,0,15,0,0,0],(i,sc[:6])
assert all(labels[f'CASE_{i:02d}']<end for i in range(len(C)))
print('Created',len(C),'cases,',len(xex),'bytes .xex; code/data',hex(origin),'-',hex(end-1))
print('Scripts length',min(map(len,SCRIPTS)),max(map(len,SCRIPTS)))
