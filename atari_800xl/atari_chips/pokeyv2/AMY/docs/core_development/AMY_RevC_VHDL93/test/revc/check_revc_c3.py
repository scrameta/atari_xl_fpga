#!/usr/bin/env python3
"""Pass/fail spectral checks for C.3 (quickclr stimulus: voice 0 = harmonics 0 and 1 at
about 1070 and 2140 Hz).
  detune_h0: +16/64 on harmonic 0 only moves 1070 Hz to ~1340 Hz and leaves 2140 Hz,
             so each coefficient lands on its own harmonic (slot alignment)
  white:     voice 0 as type 3 has no line left at 1070/2140 Hz, about the same power"""
import sys, numpy as np
FS = 32000
def load(p):
    x = np.array([float(l.split()[0]) for l in open(p) if l.strip()])[60:]
    return x - x.mean()
def spec(x):
    n = len(x); S = np.abs(np.fft.rfft(x * np.hanning(n), 1 << 15)) ** 2
    return np.fft.rfftfreq(1 << 15, 1 / FS), S
def band(f, S, c, w=60):
    return S[(f > c - w) & (f < c + w)].sum() / S.sum()
leg, det, wht = map(load, sys.argv[1:4])
ok = True
f, S = spec(leg); l1, l2 = band(f, S, 1070), band(f, S, 2140)
f, S = spec(det); d1, d1n, d2 = band(f, S, 1070), band(f, S, 1340), band(f, S, 2140)
f, S = spec(wht); w1, w2 = band(f, S, 1070), band(f, S, 2140)
def check(cond, msg):
    global ok
    print(('  PASS ' if cond else '  FAIL ') + msg); ok &= bool(cond)
check(d1 < 0.1 * l1 and d1n > 0.5 * l1, f"detune_h0 moves harmonic 0 (1070 Hz: {l1:.2f} -> {d1:.2f}, 1340 Hz: {d1n:.2f})")
check(d2 > 0.5 * l2, f"detune_h0 leaves harmonic 1 (2140 Hz: {l2:.2f} -> {d2:.2f})")
check(w1 + w2 < 0.05 * (l1 + l2), f"white leaves no tone (1070+2140 Hz energy {l1 + l2:.2f} -> {w1 + w2:.3f})")
r = wht.std() / leg.std()
check(0.7 < r < 1.4, f"white power close to the tone's (RMS ratio {r:.2f})")
sys.exit(0 if ok else 1)
