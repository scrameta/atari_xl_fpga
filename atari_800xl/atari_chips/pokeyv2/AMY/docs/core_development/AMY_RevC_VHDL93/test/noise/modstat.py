import amynoise, numpy as np
def sx(w): return w-4096 if w>=2048 else w
def seq(S, fix, n=20000, prb=(0x1234,0x4D2B,0x7A11), ud=0, bb=0):
    g=dict(a=prb[0],b=prb[1],c=prb[2],ud=ud,bb=bb,s=S)
    m=amynoise.Noise(amynoise.image([g,g]),fix=fix)
    o=[]
    for i in range(n):
        m.pass_()
        o.append(sx(m.out[0]))
    return np.array(o[::2],float)    # generator 0, one value per update (every 2 samples)
def stats(o):
    o=o[200:]
    X=np.abs(np.fft.rfft((o-o.mean())*np.hanning(len(o))))**2
    f=np.fft.rfftfreq(len(o),2/32552.)
    c=np.cumsum(X)/X.sum(); f50=f[np.searchsorted(c,0.5)]
    return o.std(), f50, len(set(o.astype(int)))
print('%-6s %-5s %8s %8s %6s'%('S','fix','std','f50Hz','vals'))
for S in (0xFFF,0x7FF,0x3FF,0x0FF,0x03F,0x00F,0x003,0x800,0xC00,0xF00,0x000):
    for fix in (False,True):
        sd,f50,nv=stats(seq(S,fix))
        print('%03x    %-5s %8.1f %8.0f %6d'%(S,fix,sd,f50,nv))
