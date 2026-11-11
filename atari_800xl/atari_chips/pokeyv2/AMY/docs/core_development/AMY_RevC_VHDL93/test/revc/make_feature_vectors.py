#!/usr/bin/env python3
"""Generate comparable 6502 bus traces for the full-RTL feature smoke runs.
Each line is: 5ns-time-units, register 0..7, value 0..255. No synthetic VHDL overrides.
"""
from pathlib import Path
P = Path(__file__).resolve().parent
SRC = P.parent/'cmds'/'cmds_quickclr_spec.txt'
base = [tuple(map(int,l.split())) for l in SRC.read_text().splitlines() if l.strip()]
assert max(t for t,_,_ in base) < 100_000

def make(extra):
    cmds = base[:]
    t = 160_000
    for a,v in extra:
        cmds.append((t,a,v)); t += 2_000  # well over a full command latency
    cmds.sort()
    assert all(b[0]>a[0] for a,b in zip(cmds,cmds[1:])), 'overlapping commands'
    return '\n'.join(f'{t} {a} {v}' for t,a,v in cmds)+'\n'

def ext(kind, idx, value):
    return [(1,idx),(3,value),(0,kind)]
unlock=[(7,0xA5),(7,0x5A)]
lock=[(7,0)]
# Enable only: should be bit-exact (no instrument changes, no noise mode 3)
(P/'cmds_enabled_zero.txt').write_text(make(unlock))
(P/'cmds_att.txt').write_text(make(unlock+sum((ext(0x34,voice,128) for voice in (0,1,2)), [])))
(P/'cmds_detune.txt').write_text(make(unlock+sum((ext(0x35,h,16) for h in range(8)), [])))
(P/'cmds_stoch.txt').write_text(make(unlock+sum((ext(0x36,h,24) for h in range(8)), [])))
(P/'cmds_white.txt').write_text(make(unlock+[(1,3),(0,0x10)]))
# Detune on harmonic 0 only: catches slot misalignment, which detuning all harmonics alike hides
(P/'cmds_detune_h0.txt').write_text(make(unlock+ext(0x35,0,16)))
(P/'cmds_all.txt').write_text(make(unlock+
     sum((ext(0x34,v,64) for v in range(3)),[])+
     sum((ext(0x35,h,16) for h in range(8)),[])+
     sum((ext(0x36,h,24) for h in range(8)),[])+
     [(1,3),(0,0x10)]))
(P/'cmds_reset.txt').write_text(make(unlock+
     ext(0x35,5,16)+ext(0x36,5,24)+[(0,0x39)]))
(P/'cmds_lock.txt').write_text(make(unlock+ext(0x35,5,16)+lock))
print('Generated nine feature bus traces in', P)
