"""Port of PARSE.C (AMY Music Box, Palevich 1983): Atari Music Composer file -> 4 voices of
(note, velocity, on_units, gap_units) events. note: semitones from C3 per the original (-12 offset), None = rest."""
import sys
XP=[0,2,4,5,7,9,11]; XA=[0,1,-1,0]
XD=[2,3,4,6,8,12,16,24,32,48,64,96]; XS=[1,1,2,2,3,3,4,4,5,5,6,6]
def parse(m):
    phrases={}; voices={}; misc=None; i=0
    while i<len(m):
        if m[i]==255: break
        if m[i]!=170: raise ValueError('bad rec %d at %d'%(m[i],i))
        v=m[i+1]//2
        if v<=13:
            i+=2; st=i
            while m[i]!=255: i+=2
            (phrases if v<=9 else voices)[v if v<=9 else v-10]=m[st:i+1]; i+=1
        elif v==64:
            i+=2; misc=m[i:i+5]; i+=5
        else: raise ValueError('weird %d'%v)
    tempo=misc[2]
    out=[]
    for vn in range(4):
        vp=voices.get(vn); ev=[]
        if vp is None: out.append(ev); continue
        vline=1; count=1; vol=4; tr=0; guard=0
        while True:
            guard+=1
            if guard>10000: raise ValueError('loop')
            j=(vline-1)*2; vline+=1
            c=vp[j]
            if c==255: break
            a=vp[j+1]
            if c==1:
                count-=1
                if count>0: vline=a
            elif c==2: ev+=phrase(phrases.get(a),tr,vol)
            elif c==3: tr+= -(a&127) if a&128 else a
            elif c==4: vol=a
            elif c==6: count=a
        # ties
        res=[]; k=0
        while k<len(ev):
            n,vel,d,g=ev[k]
            while g==0 and k+1<len(ev):
                nn=ev[k+1]
                if nn[0]!=n: d-=1; g+=1        # slur
                else: d+=nn[2]; g+=nn[3]; k+=1  # tie
            if g==0: g=1
            res.append([n,vel,d,g]); k+=1
        out.append(res)
    return tempo,out,misc
def phrase(v,tran,vol):
    ev=[]
    if v is None: return ev
    p=2; mflag=1
    while v[p]!=255:
        b=v[p]
        if b<87:
            j=b>>2
            n=None if (vol==0 or b==85) else tran+12*(j//7)+XP[j%7]+XA[b&3]-12
            vel=vol*32
            if mflag: mflag=0; vel+=16
            d=v[p+1]; jj=(d&127)-1
            if d&128: ev.append([n,vel,XD[jj],0])
            else: ev.append([n,vel,XD[jj]-XS[jj],XS[jj]])
        elif b==127: mflag=1
        p+=2
    return ev
if __name__=='__main__':
    for f in sys.argv[1:]:
        try:
            m=open(f,'rb').read(); t,o,misc=parse(m)
            ns=[e[0] for v in o for e in v if e[0] is not None]
            secs=[sum(e[2]+e[3] for e in v)*t/72.8 for v in o]
            print('%-22s %5d B tempo %3d misc %s ev %s notes %s..%s len %ss'%(f,len(m),t,list(misc),[len(v) for v in o],min(ns) if ns else '-',max(ns) if ns else '-',[round(s) for s in secs]))
        except Exception as e: print(f,'ERR',e)
