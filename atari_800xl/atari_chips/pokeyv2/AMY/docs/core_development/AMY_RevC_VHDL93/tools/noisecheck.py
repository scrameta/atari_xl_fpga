#!/usr/bin/env python3
"""noisecheck.py <busy_file> <dir of amynoise.py>: the noise generators in a tb_top run
(BUSY_FILE with NZ_ALL and NZ_WORDS) against the bit-exact model, test/noise/amynoise.py
with the PRB repair.

  * every generator pass after NZINIT: the model starts from the Noise RAM as the run left
    it after 3 passes of each generator and predicts all 32 row writes of every later pass;
  * every output word: the model's word for each pass (once the shared output chain has
    filled) must be the generator's word by the start of the next sample period.
Works with 64 and 40 harmonics (with 40, a pass spans sample periods: AMY1_SPEC.md Q6)."""
import sys
sys.path.insert(0, sys.argv[2])
from amynoise import Noise

rows, zs, scr = [], [], None
for l in open(sys.argv[1]):
    f = l.split()
    if f[0] == 'N': rows.append((int(f[1]), int(f[2], 16), int(f[3], 16)))
    elif f[0] == 'Z': zs.append((int(f[1]), int(f[2]), int(f[3], 16)))
    elif f[1] == '31': scr = int(f[0])                  # the SCR that ends NZINIT
last = rows[-1][0]
passes, cur = [], {}
for t, a, d in rows:
    if t <= scr: continue
    g = 1 - (a & 1); r = a >> 1                          # RAM address = row & not gen
    cur.setdefault(g, {})[r] = d
    if r == 31:
        if len(cur[g]) == 32: passes.append((t, g, [cur[g][i] for i in range(32)]))
        cur[g] = {}
START = 6
ram = [0] * 64                                           # model: command address row*2 + gen
for _, g, v in passes[:START]:
    for r in range(32): ram[r * 2 + g] = v[r]
n = Noise(ram, fix=True)
ok = bad = 0; words = []
for i, (t, g, v) in enumerate(passes[START:]):
    w = n.pass_(g)
    if [n.ram[r * 2 + g] for r in range(32)] == v: ok += 1
    else: bad += 1
    if i >= 12: words.append((t, g, w))
def word_at(g, t):
    v = None
    for tt, gg, w in zs:
        if tt > t: break
        if gg == g: v = w
    return v
wok = wbad = 0
for t, g, w in words:
    if t + 90 > last: continue                           # the run ended before the word was due
    if word_at(g, t + 90) == w: wok += 1
    else: wbad += 1
gens = [g for _, g, _ in passes]
alt = all(a != b for a, b in zip(gens, gens[1:]))
print(f"{len(passes)} passes, generators alternate: {alt}; row writes: {ok} passes match the model, "
      f"{bad} differ; words: {wok} match, {wbad} differ")
sys.exit(0 if bad == 0 and wbad == 0 and alt else 1)
