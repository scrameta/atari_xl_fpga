#!/usr/bin/env python3
"""Check that simulations produced numeric PCM and report levels/differences.
Deliberately reports, rather than asserts, acoustic feature effect: the existing Atari
instrument files do not guarantee that every coefficient targets an audible partial.
"""
import sys, math
from pathlib import Path

def read(path):
    result=[]
    for i,line in enumerate(Path(path).read_text().splitlines()):
        a=line.split()
        if not a:continue
        assert len(a)==2, (path,i,line)
        x,y=map(int,a)
        assert all(-32768<=v<=32767 for v in (x,y)), (path,i,line)
        result.append((x,y))
    assert result, ('no PCM samples',path)
    return result
ref=read(sys.argv[1]); cand=read(sys.argv[2]); tag=sys.argv[3]
n=min(len(ref),len(cand)); assert n>5
rms=lambda p: math.sqrt(sum(x*x for x,y in p)/len(p))
diffs=sum(ref[i]!=cand[i] for i in range(n))
print(f'  {tag}: samples {len(cand)}, RMS L {rms(cand):.2f}, different vs legacy {diffs}/{n}')
if diffs==0:print(f'  WARNING: {tag} produced no PCM change in this stimulus; use a targeted instrument')
