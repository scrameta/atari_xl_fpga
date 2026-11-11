"""Lightweight port-map/declared-port check. NOT a VHDL compiler."""
import re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
files=list((ROOT/'vhdl').glob('*.vhd'))+list((ROOT/'test/revc').glob('*.vhd'))
def clean(s):
    return re.sub(r'--[^\n]*','',s)
def balanced(s,i,left='(',right=')'):
    assert s[i]==left
    n=0
    for j in range(i,len(s)):
        if s[j]==left:n+=1
        if s[j]==right:
            n-=1
            if not n:return s[i+1:j],j+1
    raise AssertionError('unclosed '+left)
def fields(s):
    # port declarations; ':' followed by type, and next ';'
    out=set()
    for d in s.split(';'):
        m=re.match(r'\s*([\w\s,]+)\s*:\s*(?:inout|buffer|in|out)\b',d,re.I)
        if m: out.update(x.strip().lower() for x in m.group(1).split(','))
    return out
entities={}
for f in (ROOT/'vhdl').glob('*.vhd'):
    s=clean(f.read_text())
    for m in re.finditer(r'\bentity\s+(\w+)\s+is',s,re.I):
        start=s.find('port',m.end())
        if start<0:continue
        i=s.find('(',start)
        if i<0:continue
        ports,_=balanced(s,i)
        entities[m.group(1).lower()]=fields(ports)
problems=[]
for f in files:
    s=clean(f.read_text())
    for m in re.finditer(r'\bentity\s+work\.(\w+)\s*(?:\(\w+\))?\s+port\s+map\s*\(',s,re.I):
        name=m.group(1).lower(); args,_=balanced(s,m.end()-1)
        actual=set(x.lower() for x in re.findall(r'\b(\w+)\s*=>',args)) - {'others'}
        formal=entities.get(name)
        if formal is None:continue
        unknown=actual-formal
        if unknown:problems.append(f'{f.relative_to(ROOT)} → {name}: undeclared {unknown}')
        if name in ['amy1','amy1_core','amy1_mem','amy1_top','amy1_ext_phase','amy1_phase_generator']:
            print('Checked',f.relative_to(ROOT),'→',name,'missing',formal-actual)
if problems:raise AssertionError('\n'.join(problems))
print(f'PASS: named formal ports in {len(files)} HDL files; {len(entities)} entities (not a compile check)')
