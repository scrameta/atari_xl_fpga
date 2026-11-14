"""Fast structural and PRBS verification; *not* an HDL simulation."""
from pathlib import Path
r=Path(__file__).parent/'vhdl'
top=(r/'amy1_top.vhd').read_text()
core=(r/'amy1_core.vhd').read_text()
noise=(r/'amy1_noise_generator.vhd').read_text()
env=(r/'amy1_envelope_generator.vhd').read_text()
assert 'ADDR = "0111"' in top
assert 'DI = x"A5"' in top and 'DI = x"5A"' in top
assert "ext_enable_reg <= '0';" in top
assert 'ext_enable   => ext_enable_reg' in top
assert 'white_sel => white_sel' in core
assert 'vt_reg = "11"' in env
assert 'white_lfsr_reg(15) xor white_lfsr_reg(13)' in noise
# Verify primitive polynomial cycles through nonzero 16-bit states (period 65535).
state=0xACE1; seen=set(); vals=[]
for i in range(65535):
    assert state and state not in seen
    seen.add(state); vals.append(state & 0xfff)
    feedback=((state>>15)^(state>>13)^(state>>12)^(state>>10)) & 1
    state=((state<<1)&0xffff)|feedback
assert state==0xACE1 and len(seen)==65535
assert min(vals)==0 and max(vals)==4095
from collections import Counter
hist=Counter(vals)
assert min(hist.values()) == 15 and max(hist.values()) == 16
print('PASS: wiring/enable-source structural checks and full 65,535-state LFSR cycle')
print('NOTE: compile/simulation, exact legacy stream and audio spectrum are NOT tested here')
