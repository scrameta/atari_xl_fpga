"""Compare phase B RAM writes (with the Q1 fixes) against phase A's: drop the immediate-jump
current-value writes and diff the rest.
  harmonic: an hcv write in the same clock as an hbp write with mantissa 0 (same harmonic)
  voice:    a v18 write to word 0 of voice v one chip clock after a jump breakpoint write
            (v18 + v3 to word 1 of voice v with mantissa v18(1..0) & v3 = 0)
usage: q1check.py phaseA_mem.txt phaseB_mem.txt [last_clock]
Since the Q1 fixes (5-6 Nov) phase B's samples and read-backs differ from phase A's by design (a jump
is heard and read back from the command, not up to two periods later); this is the RAM-write check.
"""
import sys
def rd(p, n=None):
    out = []
    for l in open(p):
        a = l.split()
        if n is not None and int(a[0]) > n: break
        out.append(tuple(a))
    return out
n = int(sys.argv[3]) if len(sys.argv) > 3 else None
A = rd(sys.argv[1], n); B = rd(sys.argv[2], n)
hj = {(c, ad) for c, nm, ad, d in B if nm == 'hbp' and int(d, 16) & 0x1F == 0}
v18 = {(c, ad): int(d, 16) for c, nm, ad, d in B if nm == 'v18'}
v3 = {(c, ad): int(d, 16) for c, nm, ad, d in B if nm == 'v3'}
# voice addresses are logged inverted (netlist order): logical word 1 (breakpoint) is an even
# log address, and the voice's word 0 (current value) is the log address + 1
fj = set()
for (c, ad), d in v18.items():
    a = int(ad, 16)
    if not a & 1 and (c, ad) in v3 and ((d & 3) << 3 | v3[(c, ad)]) == 0:
        fj.add((str(int(c) + 1), '%X' % (a + 1)))
fjc = {c for c, ad in fj}
def extra(x):
    return (x[1] == 'hcv' and (x[0], x[2]) in hj) or (x[1] == 'v18' and (x[0], x[2]) in fj)
ex = [x for x in B if extra(x)]; Bf = [x for x in B if not extra(x)]
# the envelope's own current-value write displaced by a jump's write in the same clock
disp = [x for x in A if x[1] == 'v18' and x[0] in fjc and int(x[2], 16) & 1]
A = [x for x in A if not (x[1] == 'v18' and x[0] in fjc and int(x[2], 16) & 1)]
def first_diff(a, b):
    i = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), None)
    return min(len(a), len(b)) if i is None and len(a) != len(b) else i
nh = sum(1 for x in ex if x[1] == 'hcv'); nf = len(ex) - nh
d_all = first_diff(A, Bf)
d_noph = first_diff([x for x in A if x[1] != 'ph'], [x for x in Bf if x[1] != 'ph'])
if d_all is None: rest = 'identical (%d writes)' % len(A)
elif d_noph is None: rest = 'identical except PHASERAM (a frequency jump applied earlier: phase offset)'
else:
    a2 = [x for x in A if x[1] != 'ph']; b2 = [x for x in Bf if x[1] != 'ph']
    rest = 'DIFFER at write %d: A %s, B %s' % (d_noph, a2[d_noph:d_noph+2], b2[d_noph:d_noph+2])
print('%d harmonic + %d frequency jump writes added, %d envelope writes displaced; other RAM writes %s' % (nh, nf, len(disp), rest))
