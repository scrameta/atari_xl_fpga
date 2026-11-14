#!/usr/bin/env python3
"""Inspect a recorded PCM WAV from AMY_FEATURE_TEST.xex.

No sound synthesis is assumed correct: displays measured RMS, dominant frequency,
spectral flatness, and silent gaps for the 37 manifest sections.
"""
import argparse, csv, json, math, pathlib, wave
import numpy as np

HERE=pathlib.Path(__file__).resolve().parent
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('wav',help='Recorded uncompressed PCM WAV (mono or stereo)')
ap.add_argument('--start',type=float,help='Seconds in WAV where first sound begins; otherwise autodetect')
ap.add_argument('--output',help='Path to output CSV (default WAV basename + _analysis.csv)')
args=ap.parse_args()

def pcm_read(path):
    with wave.open(path,'rb') as w:
        ch=w.getnchannels();fs=w.getframerate();n=w.getnframes();bits=w.getsampwidth()
        raw=w.readframes(n)
    if bits==1:
        samples=np.frombuffer(raw,dtype=np.uint8).astype(np.float64)
        samples=(samples-128.0)/128.0
    elif bits==2:samples=np.frombuffer(raw,dtype='<i2').astype(np.float64)/32768.0
    elif bits==3:
        b=np.frombuffer(raw,dtype=np.uint8).reshape(-1,3).astype(np.int32)
        x=b[:,0]|(b[:,1]<<8)|(b[:,2]<<16)
        x=np.where(x&(1<<23),x-(1<<24),x)
        samples=x.astype(np.float64)/(1<<23)
    elif bits==4:samples=np.frombuffer(raw,dtype='<i4').astype(np.float64)/(1<<31)
    else:raise ValueError(f'Unsupported sample byte width: {bits}')
    return samples.reshape(-1,ch),fs

x,fs=pcm_read(args.wav)
mono=x.mean(axis=1)
cliplen=len(mono)/fs
manifest=json.loads((HERE/'MANIFEST.json').read_text())
cases=manifest['cases']

def db(x):return 20*math.log10(max(1e-12,float(x)))

def rms(x):return math.sqrt(float(np.mean(x*x))) if len(x)>0 else 0

if args.start is not None:
    t0=args.start
else:
    # Earliest clearly audible 10ms window. If first test is quieter than later
    # tests or the capture has ambient noise, --start is more reliable.
    size=max(1,round(fs*.010))
    trim=(len(mono)//size)*size
    powers=np.mean(mono[:trim].reshape(-1,size)**2,axis=1)
    levels=np.sqrt(powers)
    floor=np.quantile(levels,0.10)
    threshold=max(float(np.max(levels))*.025, float(floor)*4, 1e-4)
    found=np.flatnonzero(levels>threshold)
    if len(found)==0:raise RuntimeError('Could not find first sound. Use --start to set it.')
    t0=max(0.0,float(found[0]*size/fs))

results=[]
print('WAV',args.wav, f'{fs} Hz {x.shape[1]} channel(s), {cliplen:.3f} s')
print(f'First onset at {t0:.3f} seconds (change with --start if necessary)')
if cliplen<t0+(len(cases)-1)*.6+.5:
    print('WARNING: WAV ends before the complete last test segment.')
print(' #  Name                                  RMS dBFS   Peak Hz    Flatness   gap dBFS')
for i,d in enumerate(cases):
    start=t0+i*.6
    # Skip the first/last 40ms to avoid the switching transients.
    a=max(0,int(round((start+.05)*fs)));b=min(len(mono),int(round((start+.46)*fs)))
    section=mono[a:b]
    ga=max(0,int(round((start+.52)*fs)));gb=min(len(mono),int(round((start+.58)*fs)))
    gap=mono[ga:gb]
    if not len(section):continue
    rmsv=rms(section)
    # Welch-like single-window spectrum: useful diagnostic, not a metrology result.
    m=min(len(section),int(.35*fs))
    yy=section[:m] * np.hanning(m)
    spec=np.abs(np.fft.rfft(yy))**2
    freq=np.fft.rfftfreq(m,1/fs)
    usable=(freq>50)&(freq<min(12000,fs*.48))
    idx=np.flatnonzero(usable)
    fpeak=float(freq[idx[np.argmax(spec[idx])]]) if len(idx) else 0
    power=spec[idx] if len(idx) else np.array([1.])
    flat=float(np.exp(np.mean(np.log(np.maximum(power,1e-20))))/np.maximum(np.mean(power),1e-20))
    left=rms(x[a:b,0])
    right=rms(x[a:b,1]) if x.shape[1]>1 else left
    row=dict(segment=i+1,group=d['group'],name=d['name'],onset_s=f'{start:.3f}',
             rms_dbfs=round(db(rmsv),1),dominant_hz=round(fpeak,1),spectral_flatness=round(flat,5),
             gap_dbfs=round(db(rms(gap)),1),left_dbfs=round(db(left),1),right_dbfs=round(db(right),1))
    results.append(row)
    print(f"{i+1:2d}  {d['name'][:36]:36s} {db(rmsv):8.1f} {fpeak:9.1f} {flat:10.5f} {db(rms(gap)):9.1f}")

if len(results)==len(cases):
    reference=results[0]['rms_dbfs']
    print('\nUseful level comparisons against case 1 (clean sine):')
    for i in [11,15,18,19]:
        r=results[i]
        print(f"  {i+1:02} {r['name']}: {r['rms_dbfs']-reference:+.1f} dB")
    print('  If 6/12 dB attenuation works, cases 19/20 should be ~-6/-12 dB vs case 1.')
    print('  Case 12 global half volume should be ~-6 dB vs case 1.')
    print('  Compare 1 and 16 (locked baseline/unlocked zero) for near-equal RMS/pitch.')

path=pathlib.Path(args.output) if args.output else pathlib.Path(args.wav).with_name(pathlib.Path(args.wav).stem+'_analysis.csv')
with path.open('w',newline='') as f:
    if results:
        writer=csv.DictWriter(f,fieldnames=list(results[0]));writer.writeheader();writer.writerows(results)
print('\nWrote',path)
