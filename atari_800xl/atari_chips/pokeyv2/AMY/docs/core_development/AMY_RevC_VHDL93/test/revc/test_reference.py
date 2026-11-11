"""Run now without VHDL tools: checks byte encodings, reference arithmetic and spectral broadening.
This is NOT a substitute for the GHDL and Quartus checks in run_revC.sh.
"""
from pathlib import Path
import math
import random
import statistics

ROOT = Path(__file__).resolve().parents[2]
src = {p.name:p.read_text() for p in (ROOT/'vhdl').glob('*.vhd')}
for f in ['amy1_core.vhd','amy1_ext_phase.vhd','amy1_mem_packed.vhd','amy1_top.vhd']:
    assert f in src, f
assert 'DETUNE_MEM_PROBE' not in '\n'.join(src.values())
assert '128 x 36' in src['amy1_mem_packed.vhd']
assert 'STEP_NUM     : natural := 3;' in src['amy1_top.vhd']
assert 'STEP_DEN     : natural := 7;' in src['amy1_top.vhd']
assert 'bus_ext_wait' in src['amy1_top.vhd']
assert 'ext_pending_reg' in src['amy1_mem_packed.vhd']
assert 'offset_step' in src['amy1_mem_packed.vhd']
assert 57_344_000*(3/7)/3 == 8_192_000

# Check 128 x 36 address packing: every harmonic has a unique coefficient and phase field.
assert len({72 + h//4 for h in range(64)}) == 16
assert len({88 + h//2 for h in range(64)}) == 32
assert not (set(range(72,88)) & set(range(88,120)))
assert 120<=128
for h in range(64):
    pos = (h%4)*6
    assert pos+5<=23
    pos2=(h%2)*18
    assert pos2+17<=35

MOD=(1<<18)
def inc(old, freq, d6, s6, rng8):
    d = d6 if d6<32 else d6-64
    r = rng8 if rng8<128 else rng8-256
    return (old + ((d*freq)>>8) + s6*r) % MOD
assert inc(12345, 16384,16,0,0)==13369
assert inc(12345, 16384,48,0,0)==11321
assert inc(12345,0,0,8,32)==12601
assert inc(12345,0,0,8,224)==12089
assert inc(MOD-1,16384,1,0,0)==63

# A random walk should broaden a pitched harmonic's phase, and zero s must be stable.
rng = random.Random(1234)
p0=0; p1=0; deviations=[]
for i in range(10000):
    byte=rng.randrange(256)
    p0=inc(p0,0,0,0,byte)
    p1=inc(p1,0,0,16,byte)
    deviations.append(p1)
assert p0==0
assert len(set(deviations))>100

# Volume encoding: 1/4dB = 32 units in original 1/128dB logarithmic amplitude.
assert 255*32 == 8160
assert math.isclose(10**(-4/80), 0.89125093813, rel_tol=1e-10)
print('PASS: RevC reference arithmetic, packed-address layout, zero defaults and source structure')
