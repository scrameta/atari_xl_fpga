import numpy as np, modstat
FS=32552.
# measured transfer of the output word to signed gain (RTL calibration, 128-unit bins)
OB=np.arange(-1024,1024,128)+64
GB=np.array([0.588,0.533,0.470,0.412,0.337,0.231,0.169,0.060,-0.060,-0.191,-0.338,-0.514,-0.667,-0.886,-1.118,-1.405])
def gain(o): return np.interp(np.clip(o,-960,960),OB,GB)
def band(o):
    g=gain(np.repeat(o,2))[400:]     # per sample (each value held 2 samples)
    dc=g.mean()**2/np.mean(g**2)
    X=np.abs(np.fft.rfft((g-g.mean())*np.hanning(len(g))))**2; f=np.fft.rfftfreq(len(g),1/FS)
    e=lambda a,b: X[(f>=a)&(f<b)].sum()/X.sum()
    return dc, e(0,50), e(50,200), e(200,800), e(800,3000), e(3000,FS/2)
print('S     fix  carrier  <50   50-200 200-800 0.8-3k  >3k   (fractions of power)')
for S in (0xFFF,0x7FF,0x3FF,0x0FF,0x03F,0x00F,0x001,0x000,0x800,0xF00,0x8FF,0x80F):
    for fix in (True,False):
        o=modstat.seq(S,fix,n=40000)
        print('%03x  %-5s '%(S,fix)+' '.join('%6.3f'%v for v in band(o)))
